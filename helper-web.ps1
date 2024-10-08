function HttpsServer {
    param(
        [string] $Domain = "exampledomain.demo",
        [string] $certFolder = ($env:TEMP),
        [string] $openSslPath
    )
    
    $certPath = (Join-Path $certFolder "https-server-test-cert.pem");
    $cerPath = (Join-Path $certFolder "https-server-test-cert.cer");
    $keyPath = (Join-Path $certFolder "https-server-test-key.pem");
    
    if (!($certPath) -or !(Test-Path $certPath)) {
        Write-Host "Generating self-signed certificate for $Domain";
        if (!($openSslPath) -or !(Test-Path $openSslPath)) {
            $openSslPath = Join-Path (get-command git.exe).Source ..\..\usr\bin\openssl.exe;
        }
    
        .$openSslPath req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout $keyPath -out $certPath `
            -subj "/C=US/ST=ExampleState/L=ExampleCity/O=ExampleCompany/OU=ExampleUnit/CN=$Domain" `
            -addext "subjectAltName = DNS:$Domain";
        .$openSslPath x509 -inform PEM -in $certPath -out $cerPath;
    
        Write-Host "Installing certificate in the Trusted Root Certification Authorities store";
        gsudo { Import-Certificate -FilePath $args[0] -CertStoreLocation Cert:\LocalMachine\Root; } -args $cerPath;
    }
    
    $hostsPath = "C:\Windows\System32\drivers\etc\hosts";
    # Map $Domain to 127.0.0.1 in the hosts file
    if (!(Get-Content $hostsPath | Where-Object { $_ -match $Domain })) {
        # Add it to the hosts file if not already there
        Write-Host "Adding $Domain to the hosts file";
        gsudo { Add-Content $args[0] "127.0.0.1 $($args[1]) # Added by https-server.ps1"; } -args $hostsPath,$Domain
    }
    
    if (!(Get-Command http-server -ErrorAction Ignore)) {
        Write-Host "Installing http-server globally";
        npm install --global http-server;
    }
    
    Write-Host "Starting https-server on https://$Domain using $certPath";
    http-server -S -C $certPath -K $keyPath -p 443;
}