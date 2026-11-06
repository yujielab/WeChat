// Where the system keeps its column down the right edge (a right inset of 64pt or more) the controls
// stand in it as a rail — Back, the calls, the details, one under the other, centred under the status bar,
// the field stopping at the column — except in the leading column of a split view, which keeps its bar.
// Everywhere else, the bars below:
// iPhone Duo bars and safe regions: every control inside the safe region at
// 44pt or more, the conversation's calls and details in its heading after the
// name, Back leading the bar at its foot on the field's row with the field's
// button (photos and drawing, or Send) after it, items overflowing into the one menu by priority,
// keeping Back and focus, and the newest message readable above the bar.
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
 {w:320,h:568,right:84,bottom:52},
 {w:320,h:568,right:59,bottom:0,overflow:true},
 {w:466,h:260,right:84,bottom:0,railOverflow:true},
 {w:445,h:320,right:0,bottom:0},
 {w:678,h:466,right:0,bottom:20,name:'22-outer-landscape'},
 {w:393,h:852,right:0,bottom:34},
 {w:626,h:890,right:0,bottom:20},
 {w:890,h:626,right:84,bottom:52,split:true},
 {w:890,h:400,right:84,bottom:20,split:true},
 {w:1280,h:900,right:84,bottom:52,split:true},
 {w:890,h:626,right:84,bottom:52,lead:true},
 {w:466,h:678,right:84,bottom:52,zoom:true},
 // Asymmetric: the system can leave room on the left only, or on both sides unequally.
 {w:466,h:678,left:47,right:0,bottom:21,name:'35-safe-left'},
 {w:890,h:626,left:20,right:84,bottom:52,lead:true}
]){await p.setViewportSize({width:c.w,height:c.h});await p.evaluate(c=>{const root=document.documentElement;for(const[k,v]of Object.entries({'--safe-top':'0px','--safe-left':(c.left||0)+'px','--safe-right':c.right+'px','--safe-bottom':c.bottom+'px'}))root.style.setProperty(k,v);root.style.fontSize=c.zoom?'212.5%':'106.25%';const two=c.split||c.lead,role=c.split?'trailing':c.lead?'leading':'single',pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout=two?'split':'stack';pane.dataset.role=role;pane.style.transform=c.split?'translate3d(calc(100% + var(--gap)),0,0)':'';testThread.setLayout(role)},c);await settle();
// The keyboard shrinks only the visual viewport; the bar rides above it.
await p.evaluate(c=>{const field=document.querySelector('.composer textarea');if(c.kb){field.focus({preventScroll:true});Object.defineProperty(visualViewport,'height',{get:()=>c.kb,configurable:true})}else{field.blur();delete visualViewport.height}visualViewport.dispatchEvent(new Event('resize'))},c);await p.waitForTimeout(250);const H=c.kb||c.h,B=c.kb?0:c.bottom;
const d=await p.evaluate(()=>{const r=e=>{const b=e.getBoundingClientRect();return{x:b.x,y:b.y,right:b.right,bottom:b.bottom,w:b.width,h:b.height}};const thread=document.querySelector('.thread'),nav=document.querySelector('.thread-nav');return{thread:r(thread),header:r(nav),scroll:r(document.querySelector('.thread-scroll')),field:r(document.querySelector('.composer .field')),action:r(document.querySelector('.composer-action')),title:r(document.querySelector('.thread-title')),items:[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>({id:e.dataset.item||'more',...r(e)})),overflow:thread.scrollWidth>thread.clientWidth,underHeader:Boolean(document.elementFromPoint(nav.getBoundingClientRect().left+100,nav.getBoundingClientRect().bottom-2)?.closest('.m'))}});console.log(JSON.stringify({case:c,items:d.items.map(i=>i.id)}));
assert.ok(d.scroll.y>=d.header.bottom-.5);assert.equal(d.underHeader,false);assert.equal(d.overflow,false);
// Everything stays inside the safe area, the Duo's own right-hand column included.
const railed=c.right>=64&&!c.lead
if(railed){
 // The rail stands in the system column; the heading and the field keep to the content beside it.
 // Below the camera and status bar: 170pt on the outer display, 118pt on the inner one; turned on its side, the camera is at the foot instead.
 const col=c.w-c.right,reserve=c.split?118:c.h>c.w?170:12,ids=d.items.map(i=>i.id),item=id=>d.items.find(i=>i.id===id)
 assert.equal(await p.evaluate(()=>document.documentElement.dataset.bars),'vertical')
 for(const b of d.items){assert.ok(b.x>=col-.5&&b.right<=Math.min(c.w,d.thread.right)+.5,'in the system column '+b.id+' '+JSON.stringify({x:b.x,right:b.right,col}));assert.ok(b.w>=44&&b.h>=44,'44pt '+b.id);assert.ok(b.y>=reserve-.5&&b.bottom<=H-B+.5,'rail vertical '+b.id+' '+JSON.stringify({reserve,...b}))}
 for(const b of[d.field,{id:'action',...d.action}])assert.ok(b.right<=col+.5&&b.x>=Math.max(d.thread.x,c.split?0:c.left||0)-.5,'the field keeps to the content '+b.id+' '+JSON.stringify({x:b.x,right:b.right,col}))
 assert.ok(d.title.right<=col+.5,'the heading stops at the column')
 // Send sits inside the end of the field (css/chat.css): a 44pt circle within the field's own box.
 assert.ok(d.action.w>=43.5&&d.action.h>=43.5,'the field\'s button is 44pt');assert.ok(d.action.x>=d.field.x-.5&&d.action.x+d.action.w<=d.field.right+.5&&d.action.y>=d.field.y-.5&&d.action.y+d.action.h<=d.field.bottom+.5,'Send inside the field '+JSON.stringify({a:d.action,f:d.field}))
 // Back leads the rail, then the calls, then the details; none beside the list.
 const order=['back','audio','video','info'].filter(id=>item(id));if(c.split)assert.ok(!item('back'),'no Back beside the list');else assert.ok(item('back'),'Back never overflows')
 if(!c.railOverflow){assert.deepEqual(ids,order,'one under the other');for(let i=1;i<order.length;i++)assert.ok(item(order[i]).y>=item(order[i-1]).bottom-.5,order[i]+' under '+order[i-1])}
 if(c.railOverflow){
  assert.ok(ids.includes('more'),'overflow button');assert.ok(item('back'),'Back stays');assert.ok(item('more').y>=item('back').bottom-.5,'the menu button follows Back')
  await p.click('.thread .bar-more');await p.locator('.menu.on').waitFor();await p.waitForTimeout(200);const b=await p.locator('.menu').boundingBox(),m=await p.locator('.thread .bar-more').boundingBox()
  assert.ok(b.x>=9&&b.y>=9&&b.y+b.height<=H-B-9,'menu safe region');assert.ok(b.x+b.width<=m.x+.5,'the menu opens beside the rail, not over it '+JSON.stringify({b,m}))
  const labels=await p.locator('.menu .menu-item .label').allTextContents();assert.ok(labels.includes('聊天信息'),'overflowed items in the menu '+labels)
  await p.getByRole('menuitemcheckbox',{name:'聊天信息',exact:true}).click();await p.waitForTimeout(250);assert.equal(await p.evaluate(()=>actions.at(-1)),'info:r');assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true)
 }
}else{
for(const b of[...d.items,d.field,{id:'action',...d.action}]){const limit=Math.min(c.w-c.right,d.thread.right),start=Math.max(d.thread.x,c.split?0:c.left||0);assert.ok(b.x>=start-.5&&b.right<=limit+.5,'safe horizontal '+b.id+' '+JSON.stringify({x:b.x,right:b.right,start,limit}));assert.ok(b.y>=-.5&&b.bottom<=H-B+.5,'safe vertical '+b.id)}
for(const b of d.items)assert.ok(b.w>=44&&b.h>=44,'44pt '+b.id)
assert.ok(d.action.w>=43.5&&d.action.h>=43.5,'the field\'s button is 44pt');assert.ok(d.action.x>=d.field.x-.5&&d.action.x+d.action.w<=d.field.right+.5,'Send inside the field '+JSON.stringify({a:d.action,f:d.field}))
const ids=d.items.map(i=>i.id),item=id=>d.items.find(i=>i.id===id)
// The heading (css/chat.css): the calls before the name, in the middle; the details after it.
for(const id of['audio','video'])if(item(id))assert.ok(item(id).right<=d.title.x+.5,id+' before the name '+JSON.stringify({b:item(id),title:d.title}))
if(item('info'))assert.ok(item('info').x>=d.title.right-.5,'info after the name')
for(const id of['audio','video','info'])if(item(id))assert.ok(item(id).y>=d.header.y-.5&&item(id).bottom<=d.header.bottom+.5,id+' in the heading')
// The bar at the foot: Back leads it, before the field; drawing and photos follow the field; one row.
// A field grown taller (long text, large type) keeps the bar on its bottom edge.
const onRow=i=>i.bottom<=d.field.bottom+.5&&i.bottom>=d.field.bottom-7
if(c.split||c.lead)assert.ok(!item('back'),'no Back beside the list or the details (the details\' Close is the way out)')
else{assert.ok(item('back'),'Back never overflows');assert.ok(item('back').x-(c.left||0)<=24,'each inset counted once '+item('back').x);assert.ok(item('back').right<=d.field.x+.5&&onRow(item('back')),'Back leads the bar '+JSON.stringify({back:item('back'),field:d.field}))}
// The field's one button (photos and drawing, or Send) sits inside its end, on the same row.
assert.ok(d.action.x>=d.field.x-.5&&d.action.right<=d.field.right+.5&&onRow(d.action),'button inside the end of the field '+JSON.stringify({action:d.action,field:d.field}))
assert.ok(d.field.bottom<=H-B+.5&&d.field.bottom>=H-B-Math.max(16,0)-30,'the bar sits at the foot '+JSON.stringify(d.field))
if(c.overflow){
 // Overflow goes by priority into the one menu, at the end of the heading; Back stays.
 assert.ok(ids.includes('more'),'overflow button');assert.ok(item('more').x>=d.title.right-.5,'menu button in the heading')
 await p.click('.thread .bar-more');await p.locator('.menu.on').waitFor();await p.waitForTimeout(200);const b=await p.locator('.menu').boundingBox();assert.ok(b.x>=9&&b.x+b.width<=c.w-c.right-9&&b.y>=9&&b.y+b.height<=H-B-9,'menu safe region')
 const m=await p.locator('.thread .bar-more').boundingBox();assert.ok(b.y>=m.y+m.height,'menu below its control '+JSON.stringify({b,m}))
 const labels=await p.locator('.menu .menu-item .label').allTextContents();assert.ok(labels.includes('聊天信息'),'overflowed items in the menu '+labels)
 await p.getByRole('menuitemcheckbox',{name:'聊天信息',exact:true}).click();await p.waitForTimeout(250);assert.equal(await p.evaluate(()=>actions.at(-1)),'info:r');assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true)
}else assert.ok(!ids.includes('more'),'nothing overflows '+ids)
}
// At the newest message, it and its status stay fully readable above the floating bar, also once
// the field grows to several lines. The room is a real element at the foot of the log: Safari leaves
// a column-reverse scroller's bottom padding out of what it scrolls.
const clear=async lines=>{await p.evaluate(n=>{const t=document.querySelector('.composer textarea');t.value=Array.from({length:n},(_,i)=>'第'+(i+1)+'行').join('\n');t.dispatchEvent(new Event('input',{bubbles:true}))},lines);await p.waitForTimeout(60);await p.waitForFunction(()=>!document.querySelector('.composer textarea').getAnimations().length);await p.waitForTimeout(60);return p.evaluate(()=>{const s=document.querySelector('.thread-scroll');s.scrollTop=0;const r=e=>e.getBoundingClientRect(),field=r(document.querySelector('.composer .field')),last=[...document.querySelectorAll('.msgs .m')].at(-1),meta=document.querySelector('.msgs > .m-meta');return{field:field.top,last:r(last).bottom,meta:meta&&meta.textContent?r(meta).bottom:0,pad:parseFloat(getComputedStyle(s).paddingBottom),foot:r(document.querySelector('.thread-foot')).height,bar:document.querySelector('.composer').offsetHeight}})}
for(const lines of[0,4]){const v=await clear(lines);assert.ok(v.last<=v.field-8&&v.meta<=v.field-8,'newest message clear of the bar '+JSON.stringify({lines,...v}));assert.equal(v.pad,0);assert.ok(Math.abs(v.foot-(v.bar+14))<=1,'foot follows the bar '+JSON.stringify(v))}
await clear(0)
if(c.name)await p.screenshot({path:path.join(OUT,c.name+'.png')})
}

// Focus follows an item into the overflow menu and back out of it as the window narrows and widens.
await p.setViewportSize({width:466,height:678});await p.evaluate(()=>{const root=document.documentElement;delete visualViewport.height;root.style.fontSize='106.25%';root.style.setProperty('--safe-right','0px');root.style.setProperty('--safe-bottom','0px');const pane=document.querySelector('.pane');document.querySelector('.shell').dataset.layout='stack';pane.dataset.role='single';pane.style.transform='';testThread.setLayout('single')});await settle()
await p.locator('.thread [data-item="info"]').focus();await p.setViewportSize({width:300,height:678});await settle();assert.equal(await p.locator('.thread .bar-more').evaluate(e=>e===document.activeElement),true,'focus moves to the menu button')
await p.setViewportSize({width:466,height:678});await settle();assert.equal(await p.locator('.thread [data-item="info"]').evaluate(e=>e===document.activeElement),true,'and back')
assert.deepEqual(errors,[]);console.log('PASS: where the system keeps its column on the right edge the controls stand in it as a rail (in the column, below the camera and status bar, one under the other, the field and heading stopping at it, overflow into a menu opening beside it); elsewhere: safe regions with 44pt targets at every window, inset and keyboard; calls and details after the name; Back leading the bar at the foot on the field row, the button after the field; overflow by priority into the heading menu keeping Back; menu safe region; overflow focus; newest message and its status clear of the bar at rest, with the keyboard and with a multi-line field')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
