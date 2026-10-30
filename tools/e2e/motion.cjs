// Motion that explains rather than decorates, checked mid-flight: presses land at once and let
// go from where they got to; the field's button opens a panel grown out of itself and turns
// around mid-way; Send takes the button's place without a second button; the field grows from
// its foot without scaling its text; reduced motion keeps the meaning without the travel.
// Uses browser-only message fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/motion.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-motion')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
;(async()=>{const browser=await chromium.launch();try{
const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2}),errors=[];p.on('pageerror',e=>errors.push(e.message))
await p.route('**/auth/status',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({authed:false})}));await p.route('**/api/**',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,messages:[]})}))
await p.goto(BASE);await p.locator('.auth').waitFor()
await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.calls={enabled:true};state.chats=new Map([['r',{id:'r',kind:'dm',name:'朋友',peer:{id:'p',display:'朋友'},unread:0}]]);const t=thread('r');t.loaded=true;t.hasMore=false;mergeMessages('r',Array.from({length:14},(_,i)=>({id:String(i),chat:'r',type:'text',text:'第'+(i+1)+'条消息',from:i%3?'me':'p',out:Boolean(i%3),ts:Date.now()-(14-i)*60000,status:'sent'})));const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';pane.dataset.role='single';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.actions=[];window.testThread=createThread(pane,{onBack:()=>actions.push('back'),onInfo:id=>actions.push('info:'+id),onDraw:id=>actions.push('draw:'+id),onCall:(id,type)=>actions.push(type+':'+id),socketSend:()=>{}});testThread.setLayout('single');await testThread.open('r')})
await sleep(500)
const clip=()=>p.evaluate(()=>getComputedStyle(document.querySelector('.composer-panel-body')).clipPath)
const actionBox=()=>p.evaluate(()=>{const b=document.querySelector('.composer-action').getBoundingClientRect();return{x:b.x,y:b.y,w:b.width,h:b.height}})

// M01 press: in within ~100ms to 0.98 without moving the button's box; out from wherever it got to.
const a0=await actionBox(),box=await p.locator('.composer-action').boundingBox()
await p.mouse.move(box.x+box.width/2,box.y+box.height/2);await p.mouse.down();await sleep(140)
const pressed=await p.evaluate(()=>{const e=document.querySelector('.composer-action');return{t:getComputedStyle(e).transform,cls:e.classList.contains('is-pressed'),layout:e.offsetLeft+','+e.offsetTop+','+e.offsetWidth}})
assert.ok(pressed.cls,'pressed on contact');const sc=parseFloat(pressed.t.split('(')[1]);assert.ok(Math.abs(sc-0.98)<0.004,'sinks to 0.98 '+pressed.t)
await p.mouse.move(box.x+box.width/2+40,box.y-60);await sleep(30)
assert.equal(await p.evaluate(()=>document.querySelector('.composer-action').classList.contains('is-pressed')),false,'sliding off lets go')
assert.equal(await p.evaluate(()=>document.querySelector('.composer').classList.contains('panel-open')),false,'a press alone does nothing')
await p.mouse.up();await sleep(250)

// M02: the panel is the button's circle when closed and grows out of it; + turns to ×.
const clipRun=()=>p.evaluate(()=>{const t=document.querySelector('.composer-panel-body').getAnimations().find(a=>a.transitionProperty==='clip-path');if(!t)return null;const c=t.effect.getComputedTiming();return{progress:c.progress,duration:c.duration}})
assert.match(await clip(),/inset\(calc\(100% - 56px\) 0px 0px calc\(100% - 56px\) round 28px\)/,'closed panel is the button')
await p.click('.composer-action');await sleep(90)
const mid=await clipRun();assert.ok(mid&&mid.progress>0.05&&mid.progress<0.95&&mid.duration>=240&&mid.duration<=320,'growing over 240-320ms, not jumping '+JSON.stringify(mid))
await sleep(400);assert.equal(await clipRun(),null);assert.match(await clip(),/inset\(0px round 24px\)/,'fully open')
const st=await p.evaluate(()=>{const a=document.querySelector('.composer-action');return{expanded:a.getAttribute('aria-expanded'),rot:getComputedStyle(a.querySelector('.action-add')).transform,items:[...document.querySelectorAll('.composer-tool')].map(b=>b.textContent),inert:document.querySelector('.composer-panel').inert}})
assert.equal(st.expanded,'true');assert.deepEqual(st.items,['照片','手绘']);assert.equal(st.inert,false)
const ang=Math.round(Math.atan2(...st.rot.split('(')[1].split(',').slice(0,2).map(Number).reverse())*180/Math.PI);assert.equal(Math.abs(ang),45,'+ turned into × '+st.rot)
assert.deepEqual(await actionBox(),a0,'the button keeps its place')
await p.screenshot({path:path.join(OUT,'31-tools-open.png')})
// Reversible: a tap mid-way turns it around from where it is (the new run starts from the
// in-between shape, neither open nor closed).
const from=await p.evaluate(()=>new Promise(done=>{const a=document.querySelector('.composer-action');a.click();setTimeout(()=>{a.click();requestAnimationFrame(()=>done(document.querySelector('.composer-panel-body').getAnimations().find(x=>x.transitionProperty==='clip-path')?.effect.getKeyframes()[0].clipPath))},90)}))
assert.ok(from&&!/^inset\(0px round 24px\)$/.test(from)&&!/^inset\(calc\(100% - 56px\) 0px 0px calc\(100% - 56px\) round 28px\)$/.test(from),'turned around from where it was '+from)
await sleep(400)
// Escape closes it; the tools act and close it.
await p.keyboard.press('Escape');await sleep(350);assert.equal(await p.evaluate(()=>document.querySelector('.composer-action').getAttribute('aria-expanded')),'false')
await p.click('.composer-action');await sleep(300);await p.click('.composer-tool[data-tool="draw"]');await sleep(300)
assert.equal(await p.evaluate(()=>actions.at(-1)),'draw:r');assert.equal(await p.evaluate(()=>document.querySelector('.composer').classList.contains('panel-open')),false)
// Outside taps close it.
await p.click('.composer-action');await sleep(300);await p.mouse.click(200,300);await sleep(300);assert.equal(await p.evaluate(()=>document.querySelector('.composer').classList.contains('panel-open')),false,'outside tap closes')
// Opened from the keyboard, focus goes in; closed, it comes back.
await p.focus('.composer-action');await p.keyboard.press('Enter');await sleep(80);assert.equal(await p.evaluate(()=>document.activeElement.dataset.tool),'photo','focus into the panel')
await p.keyboard.press('Escape');await sleep(80);assert.equal(await p.evaluate(()=>document.activeElement.classList.contains('composer-action')),true,'focus back on the button')

// M04: text turns the same button into Send, in place, one button only; clearing turns it back.
await p.click('.composer textarea');await p.keyboard.type('你好');await sleep(90)
const send=await p.evaluate(()=>{const a=document.querySelector('.composer-action');return{label:a.getAttribute('aria-label'),type:a.type,buttons:document.querySelectorAll('.composer button:not(.composer-tool)').length,bg:getComputedStyle(a).backgroundColor,sendOpacity:+getComputedStyle(a.querySelector('.action-send')).opacity}})
assert.equal(send.label,'发送');assert.equal(send.type,'submit');assert.ok(send.sendOpacity>0&&send.sendOpacity<1,'Send fades in, not cut '+send.sendOpacity)
assert.deepEqual(await actionBox(),a0,'Send holds the same place')
await sleep(300);await p.screenshot({path:path.join(OUT,'32-send.png')})
await p.click('.composer-action');await sleep(100)
assert.equal(await p.evaluate(()=>document.querySelector('.composer textarea').value),'');assert.equal(await p.evaluate(()=>document.querySelector('.composer-action').getAttribute('aria-label')),'添加照片或手绘')

// M03: the field grows from its foot over ~190ms, its capsule rounding into a rectangle; the text never scales.
await p.click('.composer textarea');const f0=await p.evaluate(()=>document.querySelector('.composer .field').getBoundingClientRect().toJSON())
await p.keyboard.type('一');for(let i=0;i<3;i++){await p.keyboard.press('Shift+Enter');await p.keyboard.type('行')}
await sleep(60);const fMid=await p.evaluate(()=>document.querySelector('.composer .field').getBoundingClientRect().toJSON())
await sleep(320);const f1=await p.evaluate(()=>{const f=document.querySelector('.composer .field'),t=f.querySelector('textarea');return{...f.getBoundingClientRect().toJSON(),radius:getComputedStyle(f).borderTopLeftRadius,tf:getComputedStyle(t).transform,caret:t.selectionStart,len:t.value.length}})
assert.ok(fMid.height>f0.height&&fMid.height<f1.height,'grows over time '+JSON.stringify([f0.height,fMid.height,f1.height]))
assert.ok(Math.abs(f1.bottom-f0.bottom)<0.5,'grows upward from its foot');assert.equal(f1.radius,'22px');assert.equal(f1.tf,'none');assert.equal(f1.caret,f1.len,'caret stays at the end')
// Capped at five lines, then it scrolls inside.
for(let i=0;i<6;i++){await p.keyboard.press('Shift+Enter');await p.keyboard.type('更多')}
await sleep(300);const cap=await p.evaluate(()=>{const t=document.querySelector('.composer textarea'),lh=parseFloat(getComputedStyle(t).lineHeight);return{h:t.clientHeight,lh,scroll:t.scrollHeight>t.clientHeight}})
assert.ok(cap.scroll&&cap.h<=cap.lh*5+18+1,'five lines, then it scrolls '+JSON.stringify(cap))
await p.screenshot({path:path.join(OUT,'33-field-grown.png')})
await p.evaluate(()=>{const t=document.querySelector('.composer textarea');t.value='';t.dispatchEvent(new Event('input',{bubbles:true}))});await sleep(300)

// Reduced motion: the panel and the field change at once, without growing or turning.
await p.emulateMedia({reducedMotion:'reduce'});await sleep(250)
const rm=await p.evaluate(()=>new Promise(done=>{document.querySelector('.composer-action').click();setTimeout(()=>{const cs=getComputedStyle(document.querySelector('.composer-panel-body'));done({clip:cs.clipPath,op:+cs.opacity})},40)}))
assert.equal(rm.clip,'none');assert.equal(rm.op,1,'there at once, without growing');await sleep(200);await p.keyboard.press('Escape');await sleep(200)
await p.click('.composer textarea');const r0=await p.evaluate(()=>document.querySelector('.composer .field').offsetHeight);await p.keyboard.press('Shift+Enter');await p.keyboard.press('Shift+Enter');await sleep(30)
assert.ok(await p.evaluate(()=>document.querySelector('.composer .field').offsetHeight)>r0+20,'height at once')
await p.emulateMedia({reducedMotion:'no-preference'})

// P1-08/09, M09: a run of calls from one side folds into one quiet record with a count that opens upward
// into every call (the arrow turning, the tapped row staying put); each side words a call for itself, and
// the list says the same.
await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js');state.chats.set('c',{id:'c',kind:'dm',name:'阿遥',peer:{id:'p2',display:'阿遥'},unread:0});const t=thread('c');t.loaded=true;t.hasMore=false;const base=Date.now()-3600000,call=(i,meta,from)=>({id:'c'+i,chat:'c',type:'call',text:'',from,out:from==='me',ts:base+i*60000,status:'sent',call:{media:'audio',missed:true,...meta}});mergeMessages('c',[{id:'t0',chat:'c',type:'text',text:'在吗？',from:'p2',out:false,ts:base-60000,status:'sent'},call(1,{result:'missed',caller:'me'},'me'),call(2,{result:'cancelled',caller:'me'},'me'),call(3,{result:'missed',caller:'me'},'me'),call(4,{result:'declined',caller:'me'},'me'),call(5,{result:'cancelled',caller:'me'},'me'),{id:'t6',chat:'c',type:'text',text:'刚才在开会',from:'p2',out:false,ts:base+6*60000,status:'sent'},call(7,{result:'missed',caller:'p2'},'p2'),call(8,{missed:false,result:'completed',duration:83,caller:'p2',media:'video'},'p2')]);await testThread.open('c')})
await sleep(500)
const calls=await p.evaluate(()=>[...document.querySelectorAll('.msgs .bubble.call-log')].map(b=>({group:b.classList.contains('call-group'),text:(b.querySelector('.call-summary .t')||b.querySelector('span'))?.textContent,count:b.querySelector('.call-count')?.textContent||'',missed:b.classList.contains('missed'),label:b.getAttribute('aria-label')||b.querySelector('.call-summary')?.getAttribute('aria-label')})))
assert.deepEqual(calls.map(c=>[c.group,c.text,c.count,c.missed]),[[true,'已取消','5 次',false],[false,'未接来电','',true],[false,'通话时长 1:23','',false]],'unanswered runs fold, each worded from this side '+JSON.stringify(calls))
const prev=await p.evaluate(async()=>{const{previewText}=await import('/js/store.js');return[previewText({type:'call',sender:'p2',meta:{media:'audio',missed:true,result:'missed',caller:'p2'}}),previewText({type:'call',sender:'me',meta:{media:'audio',missed:true,result:'missed',caller:'me'}}),previewText({type:'call',sender:'me',meta:{media:'video',missed:true}})]})
assert.deepEqual(prev,['[语音通话] 未接来电','[语音通话] 对方未接听','[视频通话] 对方未接听'],'the list says what the record says')
const grp=p.locator('.call-group').first(),sum=grp.locator('.call-summary')
const y0=(await sum.boundingBox()).y
await p.evaluate(()=>document.querySelector('.call-group .call-summary').click());await sleep(90)
const opening=await p.evaluate(()=>{const a=document.querySelector('.call-group .call-items').getAnimations().find(x=>x.transitionProperty==='grid-template-rows');return a&&a.effect.getComputedTiming().progress})
assert.ok(opening>0.05&&opening<0.95,'opens over time '+opening);await sleep(400)
const opened=await p.evaluate(()=>{const g=document.querySelector('.call-group');return{expanded:g.querySelector('.call-summary').getAttribute('aria-expanded'),items:[...g.querySelectorAll('.call-item .t')].map(e=>e.textContent),visible:g.querySelector('.call-items-inner').getBoundingClientRect().height,chev:getComputedStyle(g.querySelector('.call-chevron')).transform}})
assert.equal(opened.expanded,'true');assert.deepEqual(opened.items,['对方未接听','已取消','对方未接听','对方已拒绝','已取消']);assert.ok(opened.visible>100,'every call listed')
assert.equal(opened.chev,'none','the arrow turned')
assert.ok(Math.abs((await sum.boundingBox()).y-y0)<1,'the tapped record stays where it was')
await p.screenshot({path:path.join(OUT,'36-calls-open.png')})
assert.equal(await p.evaluate(()=>document.querySelectorAll('.msgs [role="button"].call-log').length),0,'records are not buttons')

// M07: a photo opens from its bubble — the bubble's corners (and crop, when it has one) ease away as it grows,
// and come back on the way home to the same bubble.
await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js');const c=document.createElement('canvas');c.width=1200;c.height=200;const g=c.getContext('2d');g.fillStyle='#4a7';g.fillRect(0,0,1200,200);g.fillStyle='#fff';g.fillRect(570,0,60,200);const url=c.toDataURL('image/png');state.chats.set('i',{id:'i',kind:'dm',name:'林间',peer:{id:'p3',display:'林间'},unread:0});const t=thread('i');t.loaded=true;t.hasMore=false;mergeMessages('i',[{id:'im1',chat:'i',type:'image',url,w:1200,h:200,from:'me',out:true,ts:Date.now()-60000,status:'sent'}]);await testThread.open('i')})
await sleep(600)
const opening2=await p.evaluate(()=>new Promise(done=>{document.querySelector('.bubble.media').click();setTimeout(()=>{const m=document.querySelector('.viewer-media');done(m&&getComputedStyle(m).clipPath)},50)}))
assert.match(opening2||'',/inset\(.*round [1-9]/,'starts with the bubble\'s corners (and its crop, when it has one) '+opening2)
await sleep(700);assert.equal(await p.evaluate(()=>getComputedStyle(document.querySelector('.viewer-media')).clipPath),'none','fully open, uncropped')
await p.keyboard.press('Escape');await sleep(80)
assert.match(await p.evaluate(()=>{const m=document.querySelector('.viewer-media');return m?getComputedStyle(m).clipPath:'gone'}),/inset\(|gone/,'closing takes the crop back')
await sleep(600);assert.equal(await p.evaluate(()=>document.querySelector('.bubble.media img').style.visibility),'','the bubble shows again')

// P1-11 / P2-14: settings has one way into the profile, offers haptics only where the device can play them,
// and scrolls every row fully into view above the sheet's foot, folded and unfolded.
for(const vp of[{width:466,height:678},{width:951,height:669},{width:466,height:420}]){
 await p.setViewportSize(vp);await sleep(300)
 await p.evaluate(async()=>{const{state}=await import('/js/store.js');state.me={id:'me',display:'我',username:'me'};const{openSettings}=await import('/js/views/sheets.js');openSettings({onLogout(){}})})
 await p.locator('.sheet.on').waitFor();await sleep(500)
 const st=await p.evaluate(async()=>{const b=document.querySelector('.sheet.on .sheet-body');b.scrollTop=b.scrollHeight;await new Promise(r=>setTimeout(r,120));const cells=[...b.querySelectorAll('.cell')],last=cells.at(-1).getBoundingClientRect(),sheet=document.querySelector('.sheet.on').getBoundingClientRect(),close=document.querySelector('.sheet.on .sheet-head button').getBoundingClientRect();return{labels:cells.map(c=>c.textContent.trim()),profile:b.querySelector('.profile-btn').getAttribute('aria-label'),last:last.bottom,sheet:sheet.bottom,vh:innerHeight,close:[close.top,close.bottom]}})
 assert.ok(!st.labels.some(l=>l.startsWith('编辑资料')),'one way into the profile '+st.labels);assert.match(st.profile,/编辑资料/)
 assert.ok(!st.labels.some(l=>l.startsWith('触感反馈')),'no haptics switch where nothing would play')
 assert.ok(st.last<=st.sheet-12&&st.sheet<=st.vh,'the last row scrolls fully into view '+JSON.stringify({vp,...st}))
 assert.ok(st.close[0]>=0&&st.close[1]<=st.vh,'Close in reach')
 if(vp.width===951)await p.screenshot({path:path.join(OUT,'37-settings.png')})
 await p.keyboard.press('Escape');await sleep(500)
}

assert.deepEqual(errors,[]);console.log('PASS: press in at once to 0.98 and out from where it got to, sliding off cancels; tools panel grows out of the button and turns around mid-way, + to ×, Escape/outside/tool close it, focus in and back; Send in the same place, one button; field grows from its foot with its corners, text unscaled, five lines then scrolls; reduced motion changes at once; call runs fold into one record per side that opens upward in place, worded the same in the list; photos open from and close to their bubble with its crop and corners; settings scrolls fully into view with one profile entry and no dead switches')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
