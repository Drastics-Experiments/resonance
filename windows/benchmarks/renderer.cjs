const {app,BrowserWindow,ipcMain,session,nativeImage}=require('electron');
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const repo=path.resolve(__dirname,'../..');
const args=process.argv.slice(process.argv.findIndex(value=>path.resolve(value)===__filename)+1);
const count=Number(args[0]||1000);
if(!Number.isSafeInteger(count)||count<100||count>20000)throw new Error('Choose 100 through 20000 fixture songs.');
const label='renderer';
let saveCount=0;
let lastSavedVolume=null;
let storageSummaryReads=0;
const root=require('node:fs').mkdtempSync(path.join(os.tmpdir(),'resonance-renderer-'));
app.setPath('userData',root+'/data');
app.commandLine.appendSwitch('disable-gpu');
app.whenReady().then(async()=>{
 await fs.mkdir(root,{recursive:true});
 await fs.cp(path.join(repo,'windows/ui'),root+'/ui',{recursive:true});
 await fs.appendFile(root+'/ui/app.js',`\nwindow.__lag={renderSidebar,renderServer,renderListeningHistory,fullPlayerHistoryTracks,setCatalog:()=>{serverCatalog=state.tracks.map(t=>({id:t.remoteID,title:t.title,artist:t.artist,album:t.album,duration:t.duration,artwork:t.artwork}));},render,renderLibrary,renderQueue,renderStorage,openAddSongsDialog,updateChrome,openNowPlaying,setFullPlayerQueueVisible,navigate,stopPlayback:()=>audio.pause(),getState:()=>state,playlist:()=>{selectedPlaylistID='stress';renderLibrary();},ready:true};\n`);
 const wav=Buffer.alloc(44+44100*2);wav.write('RIFF');wav.writeUInt32LE(wav.length-8,4);wav.write('WAVEfmt ',8);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);wav.writeUInt32LE(44100,24);wav.writeUInt32LE(88200,28);wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(wav.length-44,40);await fs.writeFile(root+'/silence.wav',wav);
 const cover=nativeImage.createFromBitmap(Buffer.alloc(64*64*4,130),{width:64,height:64}).toDataURL();
 const tracks=Array.from({length:count},(_,i)=>({id:`track-${i}`,title:`Song ${String(i).padStart(5,'0')}`,artist:`Artist ${i%200}`,album:`Album ${i%500}`,duration:180,available:true,filePath:root+'/silence.wav',fileUrl:`file://${root}/silence.wav`,storageLocation:'server-cache',remoteID:`remote-${i}`,syncProfileID:'default',sourceServer:'https://music.example',artwork:cover,addedAt:new Date(1700000000000+i*1000).toISOString()}));
 const ids=tracks.map(t=>t.id);
 const state={tracks,serverURL:'https://music.example',favorites:ids.filter((_,i)=>i%2===0),playlists:[{id:'liked',name:'Liked Songs',isSystem:true,trackIDs:ids.filter((_,i)=>i%2===0)},{id:'stress',name:'Large playlist',trackIDs:ids}],playbackSourceQueueIDs:ids,playbackQueueIDs:ids};
 const preload=await fs.readFile(path.join(repo,'windows/preload.cjs'),'utf8');
 for(const channel of new Set([...preload.matchAll(/ipcRenderer.invoke\("([^"]+)"/g)].map(m=>m[1]))){
  ipcMain.handle(channel,async(_event,payload)=>{
   if(channel==='library:save'){saveCount++;lastSavedVolume=payload.volume;return true;}
   if(channel==='library:load')return {state};
   if(channel==='server:credentials:load')return {clientToken:'',adminToken:''};
   if(channel==='local-import:capabilities')return {enabled:false};
   if(channel==='server:client-config')return null;
   if(channel==='library:refresh-metadata')return [];
   if(channel==='library:storage'){storageSummaryReads++;return {localBytes:0,remoteBytes:count*1000,availableBytes:1e9,capacityBytes:2e9};}
   return null;
  });
 }
 session.defaultSession.webRequest.onBeforeRequest({urls:['http://*/*','https://*/*']},(_details,callback)=>callback({cancel:true}));
 const win=new BrowserWindow({width:1360,height:850,show:false,webPreferences:{preload:path.join(repo,'windows/preload.cjs'),offscreen:true,backgroundThrottling:false}});
 win.webContents.on('console-message',(_e,...args)=>{if(args[0]>=2)console.error('RENDERER',...args.slice(0,3));});
 const started=Date.now();await win.loadFile(root+'/ui/index.html');
 for(let n=0;n<300;n++){if(await win.webContents.executeJavaScript('Boolean(window.__lag?.ready)'))break;await new Promise(r=>setTimeout(r,100));}
 if(!await win.webContents.executeJavaScript('Boolean(window.__lag?.ready)'))throw new Error('Renderer failed to initialize');
 const startupMs=Date.now()-started;
 await new Promise(r=>setTimeout(r,500));
 // Inspect Electron's accessibility tree, then exercise the controls it exposes.
 win.webContents.debugger.attach('1.3');
 const tree=await win.webContents.debugger.sendCommand('Accessibility.getFullAXTree');
 win.webContents.debugger.detach();
 const lastBlock=Math.floor((count-1)/25)*25;
 if(!tree.nodes.some(node=>node.role?.value==='button'&&node.name?.value===`Show items ${lastBlock+1} through ${count} of ${count}`))throw new Error('Offscreen row navigation is absent from the accessibility tree');
 if(!tree.nodes.some(node=>node.role?.value==='button'&&node.name?.value==='Show next items'))throw new Error('Recent-card navigation is absent from the accessibility tree');
 await win.webContents.executeJavaScript(`(async()=>{
   const wait=()=>new Promise(r=>setTimeout(r,250));
   const assert=(condition,message)=>{if(!condition)throw new Error(message);};
   document.querySelector('#libraryTrackRows > [data-start="${lastBlock}"] .sr-only').click();await wait();
   assert(document.activeElement?.dataset.trackActivate==='track-${lastBlock}','Accessible row activation failed');
   document.querySelector('#libraryTrackRows > [data-start="0"] .sr-only').focus();await wait();
   assert(document.activeElement?.dataset.trackActivate==='track-0','Keyboard row navigation failed '+JSON.stringify({active:document.activeElement.outerHTML.slice(0,300),first:document.querySelector('#libraryTrackRows > [data-start="0"]').innerHTML.slice(0,300)}));
   const recent=document.querySelector('.recent-track-list');
   const last=Math.max(...[...recent.querySelectorAll('[data-recent-track]')].map(button=>Number(button.dataset.recentTrack.slice(6))));
   [...recent.querySelectorAll('.sr-only')].find(button=>button.textContent==='Show next items').click();await wait();
   assert(document.activeElement?.dataset.recentTrack==='track-'+(last+1),'Accessible card navigation failed');
   document.activeElement.blur();recent.scrollLeft=0;window.__lag.renderLibrary();await wait();
 })()`);
 const savesBeforeVolume=saveCount;
 const volumeInputMs=await win.webContents.executeJavaScript(`(()=>{
   const start=performance.now();const input=document.querySelector('#volume');
   for(let i=0;i<10;i++){input.value=String((i+1)/10);input.dispatchEvent(new Event('input',{bubbles:true}));}
   if(document.querySelector('#fullPlayerVolume').value!=='1')throw new Error('Volume controls did not update immediately');
   return +(performance.now()-start).toFixed(2);
 })()`);
 if(saveCount!==savesBeforeVolume)throw new Error('Volume input saved before settling');
 await new Promise(r=>setTimeout(r,700));
 if(saveCount!==savesBeforeVolume+1||lastSavedVolume!==1)throw new Error('Volume burst did not save the final value exactly once');
 await win.webContents.executeJavaScript(`(()=>{const input=document.querySelector('#fullPlayerVolume');input.value='0.4';input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));})()`);
 await new Promise(r=>setTimeout(r,700));
 if(saveCount!==savesBeforeVolume+2||lastSavedVolume!==0.4)throw new Error('Committed volume change was not saved exactly once');
 const result=await win.webContents.executeJavaScript(`(async()=>{
 const measure=(fn)=>{const start=performance.now();fn();void document.querySelector('#content').scrollHeight;return +(performance.now()-start).toFixed(2);};
 const times={};
 for(const name of ['renderQueue','updateChrome','renderLibrary','render'])times[name]=Array.from({length:3},()=>measure(()=>window.__lag[name]()));
 times.playlist=measure(()=>window.__lag.playlist());
 times.search=measure(()=>{const input=document.querySelector('#search');input.value='Song 099';input.dispatchEvent(new Event('input',{bubbles:true}));});
 times.clearSearch=measure(()=>{const input=document.querySelector('#search');input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));});
 const scroller=document.querySelector('#content');await new Promise(r=>setTimeout(r,500));const intervals=[];let last=performance.now();
 for(let i=0;i<60;i++){await new Promise(requestAnimationFrame);const now=performance.now();intervals.push(now-last);last=now;scroller.scrollTo({top:(scroller.scrollHeight-scroller.clientHeight)*i/59,behavior:"instant"});}
 scroller.scrollTo({top:0,behavior:"instant"});await new Promise(r=>setTimeout(r,150));
 return {times,rows:document.querySelectorAll('.track-row').length,nodes:document.querySelectorAll('*').length,scrollFrameMaxMs:Math.max(...intervals),scrollFrameMedianMs:intervals.sort((a,b)=>a-b)[30],tracks:window.__lag.getState().tracks.length};
 })()`);
 if(count>=100) {
 result.interactions=await win.webContents.executeJavaScript(`(async()=>{
 const wait=()=>new Promise(r=>setTimeout(r,200));
 const assert=(value,message)=>{if(!value)throw new Error(message);};
 const scroll=document.querySelector('#content');
 scroll.scrollTo({top:scroll.scrollHeight,behavior:'instant'});await wait();
 assert(document.querySelector('[data-track="track-${count - 1}"]'),'Last downloaded song was not rendered');
 assert(document.querySelectorAll('[data-track]').length<200,'Too many mounted song rows');
 const last=document.querySelector('[data-track="track-${count - 1}"] [data-track-activate]');
 last.focus();last.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',altKey:true,bubbles:true}));await wait();
 assert(window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs.at(-2)==='track-${count - 1}','Keyboard reorder failed');
 assert(document.activeElement?.dataset.trackActivate==='track-${count - 1}','Keyboard reorder lost focus');
 const favorite=document.querySelector('[data-favorite="track-${count - 1}"]');favorite.click();await wait();
 assert(window.__lag.getState().favorites.includes('track-${count - 1}'),'Liking an offscreen song failed');
 const input=document.querySelector('#search');input.value='Song ${String(count - 1).padStart(5,'0')}';input.dispatchEvent(new Event('input',{bubbles:true}));await wait();
 assert(document.querySelectorAll('[data-track]').length===1,'Search did not find the last song');
 input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));await wait();
 window.__lag.openNowPlaying();window.__lag.setFullPlayerQueueVisible(true);await wait();
 const queue=document.querySelector('#fullPlayerQueue');queue.scrollTo({top:queue.scrollHeight,behavior:'instant'});await wait();
 assert(document.querySelector('[data-full-player-queue="track-${count - 1}"]'),'Last queued song is inaccessible');
 assert(document.querySelectorAll('[data-full-player-queue]').length<200,'Too many mounted queue rows');
 document.querySelector('#nowPlayingDialog').close();window.__lag.navigate('playlists');window.__lag.navigate('library');await wait();
 const recent=document.querySelector('.recent-track-list');recent.scrollTo({left:recent.scrollWidth,behavior:'instant'});await wait();
 assert(document.querySelector('[data-recent-track="track-${count - 1}"]'),'Last recent song is inaccessible '+JSON.stringify({left:recent.scrollLeft,width:recent.scrollWidth,client:recent.clientWidth,columns:getComputedStyle(recent).gridAutoColumns,ids:[...document.querySelectorAll("[data-recent-track]")].map(n=>n.dataset.recentTrack)}));
 assert(document.querySelectorAll('[data-recent-track]').length<40,'Too many mounted recent cards');
 const position=recent.scrollLeft;window.__lag.renderLibrary();await wait();
 assert(Math.abs(document.querySelector('.recent-track-list').scrollLeft-position)<2,'Recently added lost its scroll position');
 document.querySelector('[data-recent-track="track-${count - 1}"]').click();await wait();
 assert(window.__lag.getState().currentTrackID==='track-${count - 1}','Playing a newly mounted card failed');
 return {lastSong:true,keyboardReorder:true,focusRetained:true,favorite:true,search:true,lastQueueSong:true,lastRecentSong:true,recentScrollRestored:true,playback:true};
 })()`);
 }
 // Use Chromium mouse input: element.click() does not exercise pointer capture
 // or the native click target that caused playlist playback to regress.
 win.show();win.focus();win.webContents.focus();
 const settle=()=>new Promise(resolve=>setTimeout(resolve,250));
 const inspect=expression=>win.webContents.executeJavaScript(expression);
 const requireResult=async(expression,message)=>{if(!await inspect(expression))throw new Error(message);};
 const point=async selector=>inspect(`(()=>{const node=document.querySelector(${JSON.stringify(selector)});if(!node)throw new Error('Missing mouse target');const rect=node.getBoundingClientRect();return {x:Math.round(rect.x+rect.width/2),y:Math.round(rect.y+rect.height/2)};})()`);
 let mouseHeld=false;
 const mouse=(type,position)=>{
   if(type==='mouseDown')mouseHeld=true;
   if(type==='mouseUp')mouseHeld=false;
   win.webContents.sendInputEvent({type,...position,button:'left',clickCount:1,modifiers:mouseHeld?['leftButtonDown']:[]});
 };
 const click=async selector=>{const position=await point(selector);mouse('mouseMove',position);mouse('mouseDown',position);mouse('mouseUp',position);await settle();};
 await inspect(`window.__lag.stopPlayback();window.__lag.playlist();document.querySelector('#content').scrollTo({top:0,behavior:'instant'});`);
 await settle();
 await inspect(`document.querySelector('#libraryTrackRows > [data-start="0"] .sr-only')?.click();`);
 await settle();
 const primary=id=>`[data-track="${id}"] [data-track-activate]`;
 await click(primary('track-0'));
 await requireResult(`window.__lag.getState().currentTrackID==='track-0'`, 'A real playlist click did not start its song');
 const favoritesBefore=await inspect(`window.__lag.getState().favorites.includes('track-1')`);
 await click('[data-favorite="track-1"]');
 await requireResult(`window.__lag.getState().currentTrackID==='track-0' && window.__lag.getState().favorites.includes('track-1')!==${favoritesBefore}`, 'Favorite click changed playback or failed to toggle');
 // Small pointer jitter is still a click, and must not reorder the playlist.
 const orderBefore=await inspect(`JSON.stringify(window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs)`);
 const jitter=await point(primary('track-1'));
 mouse('mouseMove',jitter);mouse('mouseDown',jitter);
 mouse('mouseMove',{x:jitter.x+2,y:jitter.y+2});mouse('mouseUp',{x:jitter.x+2,y:jitter.y+2});await settle();
 await requireResult(`window.__lag.getState().currentTrackID==='track-1' && JSON.stringify(window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs)===${JSON.stringify(orderBefore)}`, 'Pointer jitter lost playback or reordered a song');
 await inspect('window.__lag.stopPlayback()');
 const source=await point(primary('track-0'));
 const target=await point(primary('track-2'));
 mouse('mouseMove',source);mouse('mouseDown',source);
 mouse('mouseMove',{x:source.x,y:source.y+10});await settle();
 mouse('mouseMove',{x:target.x,y:target.y+8});await settle();
 mouse('mouseUp',{x:target.x,y:target.y+8});await settle();
 await requireResult(`JSON.stringify(window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs.slice(0,3))==='["track-1","track-2","track-0"]'`, 'Real pointer drag did not reorder the playlist');
 await requireResult(`window.__lag.getState().currentTrackID==='track-1' && !document.querySelector('.playlist-drag-floating, .track-row.dragging')`, 'Dropping a song changed playback or left a drag preview');
 await settle();
 await click(primary('track-2'));
 await requireResult(`window.__lag.getState().currentTrackID==='track-2'`, 'Playlist clicks stopped working after a reorder');
 result.playlistMouse={click:true,favorite:true,jitter:true,dragReorder:true,noPlayOnDrop:true,clickAfterDrop:true};
 result.secondary=await win.webContents.executeJavaScript(`(async()=>{
 const wait=()=>new Promise(r=>setTimeout(r,250));
 const assert=(value,message)=>{if(!value)throw new Error(message);};
 const measure=fn=>{const start=performance.now();fn();void document.body.scrollHeight;return +(performance.now()-start).toFixed(2);};
 window.__lag.stopPlayback();window.__lag.navigate('storage');await wait();
 const storageMs=measure(()=>window.__lag.renderStorage());
 const storageRows=document.querySelectorAll('[data-storage-track]').length;
 window.__lag.openAddSongsDialog(window.__lag.getState().playlists.find(p=>p.id==='stress'));await wait();
 const addSongsRows=document.querySelectorAll('[data-add-song]').length;
 const input=document.querySelector('#addSongsSearch');
 const addSongsMs=measure(()=>{input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));});
 await wait();
 const list=document.querySelector('#addSongsList');list.scrollTo({top:list.scrollHeight,behavior:'instant'});await wait();
 assert(document.querySelector('[data-add-song="track-${count-1}"]'),'Last add-song result is inaccessible');
 assert(document.querySelectorAll('[data-add-song]').length<200,'Too many mounted add-song results');
 let button=document.querySelector('[data-add-song="track-${count-1}"]');button.focus();button.click();await wait();
 assert(!window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs.includes('track-${count-1}'),'Removing a playlist song failed');
 assert(document.activeElement?.dataset.addSong==='track-${count-1}','Playlist toggle lost keyboard focus '+JSON.stringify({active:document.activeElement.outerHTML.slice(0,250),scroll:list.scrollTop,height:list.scrollHeight,rows:document.querySelectorAll('[data-add-song]').length,dialog:document.querySelector('#addSongsDialog').open}));
 button=document.querySelector('[data-add-song="track-${count-1}"]');button.click();await wait();
 assert(window.__lag.getState().playlists.find(p=>p.id==='stress').trackIDs.includes('track-${count-1}'),'Adding a playlist song failed');
 input.value='no matching fixture song';input.dispatchEvent(new Event('input',{bubbles:true}));await wait();
 assert(document.querySelector('.add-songs-empty'),'Empty search is missing');
 input.value='Song ${String(count-1).padStart(5,'0')}';input.dispatchEvent(new Event('input',{bubbles:true}));await wait();
 assert(document.querySelectorAll('[data-add-song]').length===1,'Add-song search failed');
 document.querySelector('#addSongsDialog').close();await wait();
 document.querySelector('#storageEdit').click();await wait();
 const content=document.querySelector('#content');content.scrollTo({top:content.scrollHeight,behavior:'instant'});await wait();
 assert(document.querySelector('[data-storage-track="track-${count-1}"]'),'Last storage song is inaccessible');
 assert(document.querySelectorAll('[data-storage-track]').length<200,'Too many mounted storage rows');
 document.querySelector('[data-storage-select="track-${count-1}"]').click();await wait();
 assert(document.querySelector('[data-storage-select="track-${count-1}"]')?.getAttribute('aria-pressed')==='true','Storage selection failed');
 assert(!document.querySelector('#deleteSelectedStorage').disabled,'Storage selection did not enable deletion');
 document.querySelector('[data-storage-activate="track-${count-1}"]').click();await wait();
 assert(document.querySelector('#deleteSelectedStorage').disabled,'Storage deselection failed');
 // A document listener must not retain a detached storage screen after navigation.
 const listeners=new Set();const add=document.addEventListener;const remove=document.removeEventListener;
 document.addEventListener=function(type,fn,...args){if(type==='pointerdown')listeners.add(fn);return add.call(this,type,fn,...args);};
 document.removeEventListener=function(type,fn,...args){if(type==='pointerdown')listeners.delete(fn);return remove.call(this,type,fn,...args);};
 try {
   document.querySelector('#storageImportMenuButton').click();await wait();
   assert(listeners.size===1,'Storage menu did not install its outside-click listener '+listeners.size);
   window.__lag.navigate('library');await wait();
   assert(listeners.size===0,'Storage menu leaked a document listener after navigation');
 } finally {document.addEventListener=add;document.removeEventListener=remove;}
 return {storageMs,storageRows,addSongsMs,addSongsRows,lastStorageSong:true,storageSelection:true,lastAddSong:true,playlistToggle:true,playlistFocus:true,addSongSearch:true,storageMenuCleanup:true};
 })()`);
 result.remaining=await win.webContents.executeJavaScript(`(async()=>{
 const wait=()=>new Promise(r=>setTimeout(r,250));
 const assert=(value,message)=>{if(!value)throw new Error(message);};
 const measure=fn=>{const start=performance.now();fn();void document.body.scrollHeight;return +(performance.now()-start).toFixed(2);};
 const sidebarMs=measure(()=>window.__lag.renderSidebar());
 window.__lag.setCatalog();window.__lag.navigate('server');await wait();
 const serverMs=measure(()=>window.__lag.renderServer());
 const scroller=document.querySelector('#content');scroller.scrollTo({top:scroller.scrollHeight,behavior:'instant'});await wait();
 assert(document.querySelector('[data-remote-row="remote-${count-1}"]'),'Last server song is inaccessible');
 assert(document.querySelectorAll('[data-remote-row]').length<200,'Server mounts the whole catalog');
 document.querySelector('#syncSelected').click();await wait();
 const check=document.querySelector('[data-select-remote="remote-${count-1}"]');check.click();await wait();
 assert(document.querySelector('[data-remote-row="remote-${count-1}"]').classList.contains('selected'),'Server selection failed');
 assert(!document.querySelector('#syncAll').disabled,'Server selection did not enable download');
 document.querySelector('[data-remote-activate="remote-${count-1}"]').click();await wait();
 assert(document.querySelector('#syncAll').disabled,'Server deselection failed');
 const search=document.querySelector('#search');search.value='Song ${String(count-1).padStart(5,'0')}';search.dispatchEvent(new Event('input',{bubbles:true}));await wait();
 assert(document.querySelectorAll('[data-remote-row]').length===1,'Server search failed');
 search.value='';search.dispatchEvent(new Event('input',{bubbles:true}));
 window.__lag.navigate('library');
 const state=window.__lag.getState();
 const historyCount=Math.min(1000,${count});
 state.listeningHistory=Array.from({length:historyCount},(_,i)=>({id:'listen-'+i,trackID:'track-'+i,remoteID:'remote-'+i,profileID:'default',serverOrigin:state.serverURL,startedAt:new Date().toISOString(),listenedSeconds:90,duration:180}));
 const historyQueueMs=measure(()=>window.__lag.fullPlayerHistoryTracks());
 document.querySelector('#listeningHistoryDialog').showModal();document.querySelector('#listeningHistoryDialog').classList.add('is-open');
 const historyScreenMs=measure(()=>window.__lag.renderListeningHistory());
 document.querySelector('[data-history-mode="stats"]').click();await wait();
 document.querySelector('#historyTopSongToggle').click();await wait();
 assert(document.querySelectorAll('.history-ranked-song').length===historyCount,'History ranking lost songs');
 document.querySelector('[data-history-mode="overall"]').click();await wait();
 const bars=[...document.querySelectorAll('.history-bar')];bars.at(-1).dispatchEvent(new MouseEvent('click',{bubbles:true}));await wait();
 assert(document.querySelectorAll('.history-day-song').length===historyCount,'History day detail lost songs');
 document.querySelector('#listeningHistoryDialog').close();
 return {sidebarMs,serverMs,historyCount,historyQueueMs,historyScreenMs,serverSelection:true,serverSearch:true,historyRanking:true,historyDayDetails:true};
 })()`);
 result.navigationAndFilters=await win.webContents.executeJavaScript(`(async()=>{
   const wait=()=>new Promise(r=>setTimeout(r,250));
   const assert=(value,message)=>{if(!value)throw new Error(message);};
   const times={};const input=document.querySelector('#search');
   const query=value=>{input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));};
   window.__lag.stopPlayback();window.__lag.navigate('library');await wait();
   const sidebar=document.querySelector('#sidebarPlaylists').firstElementChild;
   for(const tab of ['playlists','storage','server','library']){
     const start=performance.now();window.__lag.navigate(tab);void document.body.offsetHeight;
     times[tab]=+(performance.now()-start).toFixed(2);await wait();
     assert(document.querySelector('#sidebarPlaylists').firstElementChild===sidebar,'Navigation rebuilt unchanged sidebar collections');
   }
   let renders=0;
   const observer=new MutationObserver(entries=>{renders+=entries.length;});
   observer.observe(document.querySelector('#content'),{childList:true});
   input.focus();
   const start=performance.now();
   for(let index=0;index<20;index++)query('discarded query '+index);
   query('Song ${String(count-1).padStart(5,'0')}');
   const typingMs=+(performance.now()-start).toFixed(2);
   const caret=input.selectionStart;await wait();observer.disconnect();
   assert(renders===1,'A typing burst must render only its final query, got '+renders);
   assert(document.querySelectorAll('[data-track]').length===1 && document.querySelector('[data-track="track-${count-1}"]'),'Latest search result is incorrect');
   assert(document.activeElement===input && input.selectionStart===caret,'Filtering changed input focus or caret');
   query('pending library query');window.__lag.navigate('storage');
   const storagePage=document.querySelector('.storage-page');await wait();
   assert(document.querySelector('.storage-page')===storagePage,'A pending search rebuilt the destination tab');
   query('');await wait();
   return {times,typingMs,oneRenderPerBurst:true,latestResult:true,inputFocus:true,cancelOnNavigation:true,sidebarRetained:true};
 })()`);
 const readsBeforeFilters=storageSummaryReads;
 await win.webContents.executeJavaScript(`(async()=>{
   const wait=()=>new Promise(r=>setTimeout(r,200));
   const input=document.querySelector('#search');
   for(const value of ['Song 000','no matching song','']){input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));await wait();}
 })()`);
 if(storageSummaryReads!==readsBeforeFilters)throw new Error('Filtering repeated the storage disk scan');
 await win.webContents.executeJavaScript(`window.__lag.getState().tracks=[...window.__lag.getState().tracks];window.__lag.renderStorage();`);
 await new Promise(r=>setTimeout(r,200));
 if(storageSummaryReads!==readsBeforeFilters+1)throw new Error('A changed library failed to refresh disk usage');
 result.navigationAndFilters.storageSummaryReused=true;
 result.navigationAndFilters.storageSummaryInvalidated=true;
 result.accessibility={offscreenRowsInTree:true,recentNavigationInTree:true,rowActivation:true,keyboardNavigation:true,cardNavigation:true};
 result.volume={inputMs:volumeInputMs,burstSavedOnce:true,commitSavedOnce:true};
 result.startupMs=startupMs;result.count=count;result.label=label;
 await fs.writeFile(root+'/result.json',JSON.stringify(result,null,2));await fs.writeFile(root+'/screen.png',(await win.webContents.capturePage()).toPNG());
 await win.webContents.executeJavaScript(`(()=>{const input=document.querySelector('#volume');input.value='0.63';input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
 const closed=new Promise(resolve=>ipcMain.once('app:close-ready',resolve));
 win.webContents.send('app:prepare-close');
 await Promise.race([closed,new Promise((_,reject)=>setTimeout(()=>reject(new Error('Close flush timed out')),5000))]);
 if(lastSavedVolume!==0.63)throw new Error('Closing lost the pending volume change');
 result.volume.closeSaved=true;
 await fs.writeFile(root+'/result.json',JSON.stringify(result,null,2));
 console.log(JSON.stringify({...result,artifacts:root}));win.destroy();app.quit();
}).catch(e=>{console.error(e);app.exit(1);});
setTimeout(()=>{console.error('Test timeout');app.exit(1);},120000).unref();
