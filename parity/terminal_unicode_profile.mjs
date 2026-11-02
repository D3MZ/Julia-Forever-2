// Test-only terminal profile. Explicit Unicode width semantics are part of every capture.
import {createRequire} from 'node:module';
import {join} from 'node:path';
const require=createRequire(process.env.PI_TERMINAL_TEST_ROOT?join(process.env.PI_TERMINAL_TEST_ROOT,'package.json'):new URL('./package.json',import.meta.url));
const {Terminal}=require('@xterm/headless');
const {Unicode11Addon}=require('@xterm/addon-unicode11');
for(const [name,version]of Object.entries({'@xterm/headless':'5.5.0','@xterm/addon-unicode11':'0.8.0'}))if(require(name+'/package.json').version!==version)throw Error('Wrong terminal dependency version: '+name);
export const terminalProfile=Object.freeze({emulator:'@xterm/headless',emulatorVersion:'5.5.0',unicodeAddon:'@xterm/addon-unicode11',unicodeAddonVersion:'0.8.0',unicodeVersion:'11',allowProposedApi:true,disableStdin:true,convertEol:false,foreground:'default',background:'default'});
export function createProfileTerminal(width,rows){const term=new Terminal({cols:width,rows:Math.max(2,rows),allowProposedApi:true,disableStdin:true,convertEol:false});term.loadAddon(new Unicode11Addon());term.unicode.activeVersion='11';return term;}
export const cellStyle=cell=>({fg:{mode:cell.getFgColorMode(),value:cell.getFgColor()},bg:{mode:cell.getBgColorMode(),value:cell.getBgColor()},bold:!!cell.isBold(),dim:!!cell.isDim(),italic:!!cell.isItalic(),underline:!!cell.isUnderline(),inverse:!!cell.isInverse(),strikethrough:!!cell.isStrikethrough(),invisible:!!cell.isInvisible()});
export async function terminalCells(frame){const term=createProfileTerminal(frame.width,frame.ansiLines.length+1);await new Promise(done=>term.write(frame.ansiLines.join('\r\n'),done));const cells=frame.ansiLines.map((_,y)=>Array.from({length:frame.width},(_,x)=>{const cell=term.buffer.active.getLine(y).getCell(x);return{x,text:cell.getChars()||' ',columns:cell.getWidth(),style:cellStyle(cell)};}));term.dispose();return cells;}
