// iPhone Duo bars and safe regions (Apple HIG, "Designing for iPhone Duo"):
// which axis bars take for each window, that every control stays inside the
// safe region at 44pt or more, that the column keeps clear of the camera /
// status bar and of the content, and that controls overflow into the one
// menu from the bottom up, keeping Back and focus.
// Uses browser-only message fixtures and intercepts auth/API; no server data is created.
// npm run dev; node tools/e2e/safe-layout.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-safe');
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
;(async()=>{const browser=await chromium.launch();try{const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:1}),errors=[];p.on('pageerror',e=>errors.push(e.message));await p.route('**/auth/status',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({authed:false})}));await p.route('**/api/**',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,messages:[]})}));await p.goto(BASE);await p.locator('.auth').waitFor();await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.chats=new Map([['r',{id:'r',kind:'dm',name:'一位名字比较长的朋友',online:true,peer:{id:'p',display:'朋友'},unread:0}],['o',{id:'o',kind:'dm',name:'另一位',unread:3}]]);const t=thread('r');t.loaded=true;t.hasMore=false;const texts=['早上好，今天见。','这张照片很好看。','晚点一起出发吧？','好的。','路上给你发消息。'],times=[0,600000,42000000,42060000,73000000];mergeMessages('r',texts.map((text,i)=>({id:String(i),chat:'r',type:'text',text,from:i===2?'p':'me',out:i!==2,ts:Date.now()-73000000+times[i],status:'sent'})));const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.actions=[];window.testThread=createThread(pane,{onBack:()=>actions.push('back'),onInfo:id=>actions.push('info:'+id),onCall:(id,type)=>actions.push(type+':'+id),onCompose:()=>actions.push('compose'),socketSend:()=>{}});testThread.setLayout('single');await testThread.open('r')});
const settle=async()=>{await p.waitForTimeout(120);await p.waitForFunction(()=>!document.documentElement.dataset.posture);await p.waitForTimeout(260)}
const visibleItems=()=>p.evaluate(()=>[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.dataset.item||'more'))
for(const c of [
 {w:466,h:678,right:84,bottom:52,axis:'vertical',name:'19-safe-layout'},
 {w:466,h:678,right:0,bottom:0,axis:'vertical',name:'20-outer-display'},
 {w:382,h:618,right:0,bottom:0,axis:'vertical'},
 {w:466,h:678,kb:380,right:84,bottom:52,axis:'vertical',overflow:true,name:'21-safe-keyboard'},
 {w:320,h:568,right:84,bottom:52,axis:'vertical'},
 {w:445,h:320,right:0,bottom:0,axis:'vertical',overflow:true},
 {w:678,h:466,right:0,bottom:20,axis:'vertical',name:'22-outer-landscape'},
 {w:393,h:852,right:0,bottom:34,axis:'horizontal'},
 {w:626,h:890,right:0,bottom:20,axis:'horizontal'},
 {w:890,h:626,right:84,bottom:52,split:true,axis:'vertical'},
 {w:890,h:400,right:84,bottom:20,split:true,axis:'vertical',overflow:true},
 {w:1280,h:900,right:84,bottom:52,split:true,axis:'vertical'},
 {w:890,h:626,right:84,bottom:52,lead:true,axis:'horizontal'},
 {w:466,h:678,right:84,bottom:52,axis:'vertical',zoom:true}
]){await p.setViewportSize({width:c.w,height:c.h});await p.evaluate(c=>{const root=document.documentElement;for(const[k,v]of Object.entries({'--safe-top':'0px','--safe-left':'0px','--safe-right':c.right+'px','--safe-bottom':c.bottom+'px'}))root.style.setProperty(k,v);root.style.fontSize=c.zoom?'212.5%':'106.25%';const two=c.split||c.lead,role=c.split?'trailing':c.lead?'leading':'single',pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout=two?'split':'stack';pane.dataset.role=role;pane.style.transform=c.split?'translate3d(calc(100% + var(--gap)),0,0)':'';testThread.setLayout(role)},c);await settle();
// The keyboard shrinks only the visual viewport; the layout viewport (and so the bar axis) stays.
await p.evaluate(c=>{if(c.kb)Object.defineProperty(visualViewport,'height',{get:()=>c.kb,configurable:true});else delete visualViewport.height;visualViewport.dispatchEvent(new Event('resize'))},c);await p.waitForTimeout(250);const H=c.kb||c.h,B=c.kb?0:c.bottom;
const d=await p.evaluate(()=>{const r=e=>{const b=e.getBoundingClientRect();return{x:b.x,y:b.y,right:b.right,bottom:b.bottom,w:b.width,h:b.height}};const thread=document.querySelector('.thread'),nav=document.querySelector('.thread-nav');return{axis:thread.dataset.bars,reserve:document.querySelector('.thread-rail').getBoundingClientRect().top,foot:document.querySelector('.thread-rail').getBoundingClientRect().bottom,thread:r(thread),header:r(nav),scroll:r(document.querySelector('.thread-scroll')),field:r(document.querySelector('.composer .field')),title:r(document.querySelector('.thread-title')),items:[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>({id:e.dataset.item||'more',...r(e)})),overflow:thread.scrollWidth>thread.clientWidth,underHeader:Boolean(document.elementFromPoint(nav.getBoundingClientRect().left+100,nav.getBoundingClientRect().bottom-2)?.closest('.m'))}});console.log(JSON.stringify({case:c,axis:d.axis,items:d.items.map(i=>i.id)}));
assert.equal(d.axis,c.axis,'bar axis');assert.ok(d.scroll.y>=d.header.bottom-.5);assert.equal(d.underHeader,false);assert.equal(d.overflow,false);
// With a wide right inset (the Duo's own column for the status bar and Dynamic Island, open or closed) the
// bars join that column, except in the leading column of a split view; everywhere else they stay inside the
// safe area. Content always does.
const edge=c.right>=64&&!c.lead
for(const b of[...d.items,d.field]){const limit=edge&&b!==d.field?c.w-4:Math.min(c.w-c.right,d.thread.right);assert.ok(b.x>=d.thread.x-.5&&b.right<=limit+.5,'safe horizontal '+b.id);assert.ok(b.y>=-.5&&b.bottom<=H-B+.5,'safe vertical '+b.id)}
for(const b of d.items)assert.ok(b.w>=44&&b.h>=44,'44pt '+b.id)
const ids=d.items.map(i=>i.id)
if(c.axis==='vertical'){
 // One column on the trailing edge, below the camera and status bar, beside the content.
 const left=Math.min(...d.items.map(i=>i.x));assert.ok(d.items.every(i=>i.x>=c.w-c.right-72),'column on the trailing edge');assert.ok(d.items.every(i=>i.y>=d.reserve-.5&&i.bottom<=d.foot+.5),'clear of camera/status bar');assert.ok(d.field.right<=left,'content beside the column');assert.ok(d.header.right<=left,'heading beside the column')
 if(!c.split)assert.equal(ids[0],'back','Back leads the column')
 if(edge){const mid=(left+Math.max(...d.items.map(i=>i.right)))/2;assert.ok(Math.abs(mid-(c.w-(c.right-34)))<1.5,'rail centred in the system column '+mid);assert.ok(d.field.right>=c.w-c.right-20-1,'content runs up to the inset (one margin) '+d.field.right)}
 else assert.ok(d.items.every(i=>i.right<=c.w-c.right+.5),'rail inside the safe area')
 for(let i=1;i<d.items.length;i++)assert.ok(d.items[i].y>=d.items[i-1].y,'column order')
 if(c.split)assert.equal(ids.at(-1),'compose','New Chat ends the column beside the list')
}else{
 // Standard bars: Back left of the title, actions after it, drawing / photos beside the field. The leading
 // column of a split view (the conversation beside its details) keeps them whatever the window's axis.
 const back=d.items.find(i=>i.id==='back');if(!c.split){assert.ok(back&&back.right<=d.title.x+.5,'Back leads the top bar')}
 for(const id of['audio','video','info'])assert.ok(d.items.find(i=>i.id===id).x>=d.title.right-.5,id+' after the title')
 for(const id of['draw','photo'])assert.ok(d.items.find(i=>i.id===id).x>=d.field.right-.5,id+' beside the field')
}
if(c.overflow){
 // Overflow is bottom-up by priority; Back never overflows; the menu holds the rest.
 assert.ok(ids.includes('more'),'overflow button');if(!c.split)assert.ok(ids.includes('back'))
 await p.click('.thread .bar-more');await p.locator('.menu.on').waitFor();await p.waitForTimeout(200);const b=await p.locator('.menu').boundingBox();assert.ok(b.x>=9&&b.x+b.width<=c.w-c.right-9&&b.y>=9&&b.y+b.height<=H-B-9,'menu safe region')
 const labels=await p.locator('.menu .menu-item .label').allTextContents();assert.ok(labels.includes('聊天信息'),'details in overflow '+labels)
 await p.getByRole('menuitemcheckbox',{name:'聊天信息',exact:true}).click();await p.waitForTimeout(250);assert.equal(await p.evaluate(()=>actions.at(-1)),'info:r');assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true)
}else assert.ok(!ids.includes('more'),'nothing overflows')
if(c.name)await p.screenshot({path:path.join(OUT,c.name+'.png')})
}

// Focus follows an item into the overflow menu and back out of it.
await p.setViewportSize({width:466,height:678});await p.evaluate(()=>{const root=document.documentElement;delete visualViewport.height;root.style.fontSize='106.25%';root.style.setProperty('--safe-right','0px');root.style.setProperty('--safe-bottom','0px');const pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout='stack';pane.dataset.role='single';pane.style.transform='';testThread.setLayout('single')});await settle()
await p.locator('.thread [data-item="info"]').focus();await p.evaluate(()=>{Object.defineProperty(visualViewport,'height',{get:()=>360,configurable:true});visualViewport.dispatchEvent(new Event('resize'))});await p.waitForTimeout(300);assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true)
await p.evaluate(()=>{delete visualViewport.height;visualViewport.dispatchEvent(new Event('resize'))});await p.waitForTimeout(300);assert.equal(await p.locator('.thread [data-item="info"]').evaluate(e=>e===document.activeElement),true)
// The same item keeps its identity (and focus) when bars change axis.
await p.locator('.thread [data-item="audio"]').focus();await p.setViewportSize({width:626,height:890});await settle();assert.equal(await p.evaluate(()=>document.querySelector('.thread').dataset.bars),'horizontal');assert.equal(await p.locator('.thread [data-item="audio"]').evaluate(e=>e===document.activeElement),true)
assert.deepEqual(errors,[]);console.log('PASS: HIG bar axis per window, safe regions with 44pt targets, camera/status clearance, trailing column beside content, bottom-up overflow keeping Back, overflow focus, axis change keeps focus')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
