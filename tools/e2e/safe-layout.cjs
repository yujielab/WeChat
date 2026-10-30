// iPhone Duo bars and safe regions: every control inside the safe region at
// 44pt or more, the conversation's calls and details in its heading after the
// name, Back leading the bar at its foot on the field's row with drawing and
// photos after the field, and items overflowing into the one menu by
// priority, keeping Back and focus.
// Uses browser-only message fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/safe-layout.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-safe');
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
;(async()=>{const browser=await chromium.launch();try{const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:1}),errors=[];p.on('pageerror',e=>errors.push(e.message));await p.route('**/auth/status',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({authed:false})}));await p.route('**/api/**',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,messages:[]})}));await p.goto(BASE);await p.locator('.auth').waitFor();await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.calls={enabled:true};state.chats=new Map([['r',{id:'r',kind:'dm',name:'一位名字比较长的朋友',online:true,peer:{id:'p',display:'朋友'},unread:0}],['o',{id:'o',kind:'dm',name:'另一位',unread:3}]]);const t=thread('r');t.loaded=true;t.hasMore=false;const texts=['早上好，今天见。','这张照片很好看。','晚点一起出发吧？','好的。','路上给你发消息。'],times=[0,600000,42000000,42060000,73000000];mergeMessages('r',texts.map((text,i)=>({id:String(i),chat:'r',type:'text',text,from:i===2?'p':'me',out:i!==2,ts:Date.now()-73000000+times[i],status:'sent'})));const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.actions=[];window.testThread=createThread(pane,{onBack:()=>actions.push('back'),onInfo:id=>actions.push('info:'+id),onCall:(id,type)=>actions.push(type+':'+id),socketSend:()=>{}});testThread.setLayout('single');await testThread.open('r')});
const settle=async()=>{await p.waitForTimeout(120);await p.waitForFunction(()=>!document.documentElement.dataset.posture);await p.waitForTimeout(260)}
const visibleItems=()=>p.evaluate(()=>[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.dataset.item||'more'))
for(const c of [
 {w:466,h:678,right:84,bottom:52,name:'19-safe-layout'},
 {w:376,h:678,right:0,bottom:0,name:'20-outer-display'},
 {w:382,h:618,right:0,bottom:0},
 {w:466,h:678,kb:380,right:84,bottom:52,name:'21-safe-keyboard'},
 {w:320,h:568,right:84,bottom:52,overflow:true},
 {w:445,h:320,right:0,bottom:0},
 {w:678,h:466,right:0,bottom:20,name:'22-outer-landscape'},
 {w:393,h:852,right:0,bottom:34},
 {w:626,h:890,right:0,bottom:20},
 {w:890,h:626,right:84,bottom:52,split:true},
 {w:890,h:400,right:84,bottom:20,split:true},
 {w:1280,h:900,right:84,bottom:52,split:true},
 {w:890,h:626,right:84,bottom:52,lead:true},
 {w:466,h:678,right:84,bottom:52,zoom:true}
]){await p.setViewportSize({width:c.w,height:c.h});await p.evaluate(c=>{const root=document.documentElement;for(const[k,v]of Object.entries({'--safe-top':'0px','--safe-left':'0px','--safe-right':c.right+'px','--safe-bottom':c.bottom+'px'}))root.style.setProperty(k,v);root.style.fontSize=c.zoom?'212.5%':'106.25%';const two=c.split||c.lead,role=c.split?'trailing':c.lead?'leading':'single',pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout=two?'split':'stack';pane.dataset.role=role;pane.style.transform=c.split?'translate3d(calc(100% + var(--gap)),0,0)':'';testThread.setLayout(role)},c);await settle();
// The keyboard shrinks only the visual viewport; the bar rides above it.
await p.evaluate(c=>{const field=document.querySelector('.composer textarea');if(c.kb){field.focus({preventScroll:true});Object.defineProperty(visualViewport,'height',{get:()=>c.kb,configurable:true})}else{field.blur();delete visualViewport.height}visualViewport.dispatchEvent(new Event('resize'))},c);await p.waitForTimeout(250);const H=c.kb||c.h,B=c.kb?0:c.bottom;
const d=await p.evaluate(()=>{const r=e=>{const b=e.getBoundingClientRect();return{x:b.x,y:b.y,right:b.right,bottom:b.bottom,w:b.width,h:b.height}};const thread=document.querySelector('.thread'),nav=document.querySelector('.thread-nav');return{thread:r(thread),header:r(nav),scroll:r(document.querySelector('.thread-scroll')),field:r(document.querySelector('.composer .field')),title:r(document.querySelector('.thread-title')),items:[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>({id:e.dataset.item||'more',...r(e)})),overflow:thread.scrollWidth>thread.clientWidth,underHeader:Boolean(document.elementFromPoint(nav.getBoundingClientRect().left+100,nav.getBoundingClientRect().bottom-2)?.closest('.m'))}});console.log(JSON.stringify({case:c,items:d.items.map(i=>i.id)}));
assert.ok(d.scroll.y>=d.header.bottom-.5);assert.equal(d.underHeader,false);assert.equal(d.overflow,false);
// Everything stays inside the safe area, the Duo's own right-hand column included.
for(const b of[...d.items,d.field]){const limit=Math.min(c.w-c.right,d.thread.right);assert.ok(b.x>=d.thread.x-.5&&b.right<=limit+.5,'safe horizontal '+b.id);assert.ok(b.y>=-.5&&b.bottom<=H-B+.5,'safe vertical '+b.id)}
for(const b of d.items)assert.ok(b.w>=44&&b.h>=44,'44pt '+b.id)
const ids=d.items.map(i=>i.id),item=id=>d.items.find(i=>i.id===id)
// The heading: the calls and the details follow the name.
for(const id of['audio','video','info'])if(item(id)){assert.ok(item(id).x>=d.title.right-.5,id+' after the name');assert.ok(item(id).y>=d.header.y-.5&&item(id).bottom<=d.header.bottom+.5,id+' in the heading')}
// The bar at the foot: Back leads it, before the field; drawing and photos follow the field; one row.
// A field grown taller (long text, large type) keeps the bar on its bottom edge.
const onRow=i=>i.bottom<=d.field.bottom+.5&&i.bottom>=d.field.bottom-7
if(c.split)assert.ok(!item('back'),'no Back beside the list')
else{assert.ok(item('back'),'Back never overflows');assert.ok(item('back').right<=d.field.x+.5&&onRow(item('back')),'Back leads the bar '+JSON.stringify({back:item('back'),field:d.field}))}
for(const id of['draw','photo'])if(item(id))assert.ok(item(id).x>=d.field.right-.5&&onRow(item(id)),id+' after the field')
assert.ok(d.field.bottom<=H-B+.5&&d.field.bottom>=H-B-Math.max(16,0)-30,'the bar sits at the foot '+JSON.stringify(d.field))
if(c.overflow){
 // Overflow goes by priority into the one menu, at the end of the heading; Back stays.
 assert.ok(ids.includes('more'),'overflow button');assert.ok(item('more').x>=d.title.right-.5,'menu button in the heading')
 await p.click('.thread .bar-more');await p.locator('.menu.on').waitFor();await p.waitForTimeout(200);const b=await p.locator('.menu').boundingBox();assert.ok(b.x>=9&&b.x+b.width<=c.w-c.right-9&&b.y>=9&&b.y+b.height<=H-B-9,'menu safe region')
 const m=await p.locator('.thread .bar-more').boundingBox();assert.ok(b.y>=m.y+m.height,'menu below its control '+JSON.stringify({b,m}))
 const labels=await p.locator('.menu .menu-item .label').allTextContents();assert.ok(labels.includes('聊天信息')&&labels.includes('照片'),'overflowed items in the menu '+labels)
 await p.getByRole('menuitemcheckbox',{name:'聊天信息',exact:true}).click();await p.waitForTimeout(250);assert.equal(await p.evaluate(()=>actions.at(-1)),'info:r');assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true)
}else assert.ok(!ids.includes('more'),'nothing overflows '+ids)
if(c.name)await p.screenshot({path:path.join(OUT,c.name+'.png')})
}

// Focus follows an item into the overflow menu and back out of it as the window narrows and widens.
await p.setViewportSize({width:466,height:678});await p.evaluate(()=>{const root=document.documentElement;delete visualViewport.height;root.style.fontSize='106.25%';root.style.setProperty('--safe-right','0px');root.style.setProperty('--safe-bottom','0px');const pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout='stack';pane.dataset.role='single';pane.style.transform='';testThread.setLayout('single')});await settle()
await p.locator('.thread [data-item="info"]').focus();await p.setViewportSize({width:300,height:678});await settle();assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true,'focus moves to the menu button')
await p.setViewportSize({width:466,height:678});await settle();assert.equal(await p.locator('.thread [data-item="info"]').evaluate(e=>e===document.activeElement),true,'and back')
assert.deepEqual(errors,[]);console.log('PASS: safe regions with 44pt targets at every window, inset and keyboard; calls and details after the name; Back leading the bar at the foot on the field row, drawing and photos after the field; overflow by priority into the heading menu keeping Back; menu safe region; overflow focus')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
