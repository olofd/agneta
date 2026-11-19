// Makes build/Project Chat.app: a copy of Electron with Project Chat inside, which Finder and the Dock open as
// Project Chat. `npm start` runs the shared Electron.app from node_modules with this folder as its app, so a Dock
// click after quitting starts bare Electron; this bundle carries the app itself (Electron loads
// Contents/Resources/app when it's there). macOS only. With AGNETA_PORT set now, the bundle keeps that port; without it,
// the app offers the release and the development build, as `npm start` does.
import { execFileSync } from 'node:child_process';
import { cp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const electron = join(root, 'node_modules/electron/dist/Electron.app');
const out = join(root, 'build/Project Chat.app');
// The app's own files, and its one dependency, @agneta/client (built: npm run build in packages/client). Electron and
// Node provide everything else.
const files = ['chat.mjs', 'main.mjs', 'preload.cjs', 'project-tools.mjs', 'renderer.js', 'index.html', 'styles.css', 'package.json'];
const client = await realpath(join(root, 'node_modules/@agneta/client'));

if (process.platform !== 'darwin') throw new Error('Project Chat.app is a macOS bundle.');
await rm(out, { recursive: true, force: true });
await mkdir(dirname(out), { recursive: true });
// ditto keeps Electron's symlinks and frameworks exactly as they are.
execFileSync('/usr/bin/ditto', [electron, out]);
const app = join(out, 'Contents/Resources/app');
await mkdir(app);
for (const file of files) await cp(join(root, file), join(app, file));
const bundledClient = join(app, 'node_modules/@agneta/client');
await mkdir(bundledClient, { recursive: true });
for (const file of ['package.json', 'dist', 'LICENSE']) await cp(join(client, file), join(bundledClient, file), { recursive: true });
if (process.env.AGNETA_PORT) await writeFile(join(app, 'port'), process.env.AGNETA_PORT);

const plist = join(out, 'Contents/Info.plist');
const set = (key, value) => execFileSync('/usr/bin/plutil', ['-replace', key, '-string', value, plist]);
set('CFBundleName', 'Project Chat');
set('CFBundleDisplayName', 'Project Chat');
set('CFBundleIdentifier', 'com.objectivecoder.agneta.example.project-chat');
// Changing the bundle breaks Electron's signature: sign it again, ad hoc, as a development build is.
execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', out], { stdio: 'ignore' });
console.log(out);
