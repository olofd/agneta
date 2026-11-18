// Makes build/Project Chat.app: a copy of Electron with Project Chat inside, which Finder and the Dock open as
// Project Chat. `npm start` runs the shared Electron.app from node_modules with this folder as its app, so a Dock
// click after quitting starts bare Electron; this bundle carries the app itself (Electron loads
// Contents/Resources/app when it's there). macOS only. It connects to AGNETA_PORT as given now, else 47331.
import { execFileSync } from 'node:child_process';
import { cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const electron = join(root, 'node_modules/electron/dist/Electron.app');
const out = join(root, 'build/Project Chat.app');
// The app's own files: no node_modules, since it uses only Node's and Electron's modules.
const files = ['acp.mjs', 'chat.mjs', 'main.mjs', 'preload.cjs', 'project-tools.mjs', 'renderer.js', 'index.html', 'styles.css', 'package.json'];

if (process.platform !== 'darwin') throw new Error('Project Chat.app is a macOS bundle.');
await rm(out, { recursive: true, force: true });
await mkdir(dirname(out), { recursive: true });
// ditto keeps Electron's symlinks and frameworks exactly as they are.
execFileSync('/usr/bin/ditto', [electron, out]);
const app = join(out, 'Contents/Resources/app');
await mkdir(app);
for (const file of files) await cp(join(root, file), join(app, file));
if (process.env.AGNETA_PORT) await writeFile(join(app, 'port'), process.env.AGNETA_PORT);

const plist = join(out, 'Contents/Info.plist');
const set = (key, value) => execFileSync('/usr/bin/plutil', ['-replace', key, '-string', value, plist]);
set('CFBundleName', 'Project Chat');
set('CFBundleDisplayName', 'Project Chat');
set('CFBundleIdentifier', 'com.objectivecoder.agneta.example.project-chat');
// Changing the bundle breaks Electron's signature: sign it again, ad hoc, as a development build is.
execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', out], { stdio: 'ignore' });
console.log(out);
