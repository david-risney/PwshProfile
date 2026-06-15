// Local ESM wrapper around the self-contained Mermaid UMD bundle
// (mermaid.min.js, pinned to mermaid v11). The upstream ESM build splits into
// 100+ lazily-imported chunk files, which cannot be shipped as a single local
// copy; the UMD bundle is one self-contained file that assigns the library to
// `globalThis.mermaid`. This wrapper runs that bundle for its side effect and
// re-exports the global as the module default, so a tour can simply:
//
//     import mermaid from './mermaid.esm.min.mjs';
//
// and work fully offline next to the generated tour HTML.
import './mermaid.min.js';
export default globalThis.mermaid;
