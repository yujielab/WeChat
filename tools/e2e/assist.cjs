// Writing help (Workers AI): the rest of the sentence in grey after the caret, a reply in an empty field;
// tap, Tab or → takes it, typing on types through it. Kept apart from the live typing preview: a suggestion
// is never in the field — and so never in what the other side sees typed — until taken, and the other
// side's preview is shown plain and survives a message's key words arriving. Key words of sent messages
// are marked in their bubbles, and the setting hides them at once.
// Uses browser-only fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/assist.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-assist')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})
const SUGGEST={'':'好的，马上到','明天':'下午三点见','明天下午三点见':''}

;(async()=>{const browser=await chromium.launch();try{
const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2}),errors=[],asked=[]
p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.route('**/auth/status',r=>r.fulfill(json({authed:false})));await p.route('**/api/**',r=>r.fulfill(json({ok:true,messages:[]})))
await p.route('**/api/ai/suggest',r=>{const b=r.request().postDataJSON();asked.push(b);r.fulfill(json({ok:true,text:SUGGEST[b.draft]??''}))})
await p.goto(BASE);await p.locator('.auth').waitFor()
await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.assist=true;state.chats=new Map([['r',{id:'r',kind:'dm',name:'pll',peer:{id:'p',display:'pll'},unread:0}]]);const t=thread('r');t.loaded=true;t.hasMore=false;mergeMessages('r',[{id:'1',chat:'r',type:'text',text:'宝贝',from:'me',out:true,ts:Date.now()-120000,status:'sent'},{id:'2',chat:'r',type:'text',text:'你到了吗？',from:'p',out:false,ts:Date.now()-60000,status:'sent'}]);const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';pane.dataset.role='single';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.sent=[];window.testThread=createThread(pane,{onBack(){},onInfo(){},onDraw(){},onCall(){},socketSend:o=>window.sent.push(o)});testThread.setLayout('single');await testThread.open('r')})
await sleep(400)
const field=()=>p.evaluate(()=>{const t=document.querySelector('.composer textarea'),l=document.querySelector('.field-predict');return{value:t.value,shown:l&&!l.hidden?l.querySelector('.rest').textContent:'',typed:l?.querySelector('.typed').textContent,placeholderHidden:t.classList.contains('has-prediction')}})
const typedFrames=()=>p.evaluate(()=>window.sent.filter(o=>o.t==='typing').map(o=>o.text))

// 1. An empty field, the last message someone else's: a reply waits in grey once the field is focused.
await p.click('.composer textarea');await sleep(500)
let f=await field();assert.deepEqual([f.value,f.shown,f.placeholderHidden],['','好的，马上到',true],'a reply in an empty field '+JSON.stringify(f))
assert.deepEqual(asked.at(-1),{room:'r',draft:''})
await p.screenshot({path:path.join(OUT,'46-assist-reply.png')})

// 2. Writing: the rest of the sentence after the caret, drawn over the field in its own box and font.
await p.keyboard.type('明天');await sleep(700)
f=await field();assert.deepEqual([f.value,f.shown,f.typed],['明天','下午三点见','明天'])
const align=await p.evaluate(()=>{const t=document.querySelector('.composer textarea'),l=document.querySelector('.field-predict'),a=t.getBoundingClientRect(),b=l.getBoundingClientRect(),ct=getComputedStyle(t),cl=getComputedStyle(l);return{box:[a.left-b.left,a.top-b.top,a.width-b.width,a.height-b.height].map(Math.round),font:ct.font===cl.font}})
assert.deepEqual(align,{box:[0,0,0,0],font:true},'laid exactly over the field')
await p.screenshot({path:path.join(OUT,'47-assist-predict.png')})
// Isolation: what the other side sees typed is the field alone, never the suggestion.
assert.ok((await typedFrames()).every(t=>!t.includes('下午')),'the suggestion never reaches the live preview '+JSON.stringify(await typedFrames()))

// 3. Typing what it says types through it, without asking again.
const before=asked.length;await p.keyboard.type('下');await sleep(600)
f=await field();assert.deepEqual([f.value,f.shown],['明天下','午三点见']);assert.equal(asked.length,before,'no new request while typing through')
assert.ok((await typedFrames()).every(t=>!t.includes('午三点')))

// 4. Tab takes it, as if typed: now it is in the field, and only now in the preview.
await p.keyboard.press('Tab');await sleep(250)
f=await field();assert.deepEqual([f.value,f.shown],['明天下午三点见',''])
assert.equal(await p.evaluate(()=>document.activeElement.matches('.composer textarea')),true,'focus stays in the field')
await sleep(300);assert.equal((await typedFrames()).at(-1),'明天下午三点见','taken text is typed text')

// 5. A tap on the grey text takes it too; Escape puts it away.
await p.evaluate(()=>{const t=document.querySelector('.composer textarea');t.value='';t.dispatchEvent(new Event('input',{bubbles:true}))});await p.keyboard.type('明天');await sleep(700)
await p.locator('.field-predict .rest').click();await sleep(200)
assert.equal((await field()).value,'明天下午三点见','tapped')
await p.evaluate(()=>{const t=document.querySelector('.composer textarea');t.value='';t.dispatchEvent(new Event('input',{bubbles:true}))});await p.keyboard.type('明天');await sleep(700)
await p.keyboard.press('Escape');await sleep(100);assert.equal((await field()).shown,'','Escape puts it away');assert.equal((await field()).value,'明天')

// 6. Switched off: no suggestions and no requests.
await p.evaluate(()=>import('/js/views/predict.js').then(m=>m.setAssistPref('predict',false)))
const n=asked.length;await p.keyboard.type('见');await sleep(700);assert.equal(asked.length,n);assert.equal((await field()).shown,'')
await p.evaluate(()=>import('/js/views/predict.js').then(m=>m.setAssistPref('predict',true)))

// 7. Key words: marked in a sent message's bubble, plain in the other side's live preview, which a
// message's key words arriving leaves in place; the setting hides the marks at once.
await p.evaluate(async()=>{const{upsertMessage}=await import('/js/store.js');upsertMessage({id:'3',chat:'r',type:'text',text:'明天下午3点在会议室见，记得带电脑',from:'p',out:false,ts:Date.now(),status:'sent',meta:{}});testThread.setTyping('r','p','明天下午3点我可能晚到')})
await sleep(300)
assert.equal(await p.locator('.bubble.ghost').count(),1,'the other side is typing')
await p.evaluate(async()=>{const{state,upsertMessage}=await import('/js/store.js');const known=state.threads.get('r').byId.get('3');upsertMessage({...known,meta:{...known.meta,keys:['明天下午3点','会议室']}})})
await sleep(300)
assert.equal(await p.locator('.bubble.ghost').count(),1,'their preview survives the key words arriving')
assert.equal(await p.locator('.bubble.ghost mark').count(),0,'their preview is shown plain')
const marks=await p.evaluate(()=>[...document.querySelectorAll('.m[data-id="3"] mark.kw')].map(m=>({text:m.textContent,weight:getComputedStyle(m).fontWeight,bg:getComputedStyle(m).backgroundColor})))
assert.deepEqual(marks.map(m=>m.text),['明天下午3点','会议室']);assert.ok(marks.every(m=>Number(m.weight)>=600&&m.bg!=='rgba(0, 0, 0, 0)'),'marked '+JSON.stringify(marks))
await p.screenshot({path:path.join(OUT,'48-assist-keys.png')})
await p.evaluate(()=>import('/js/views/predict.js').then(m=>m.setAssistPref('keys',false)))
assert.equal(await p.evaluate(()=>getComputedStyle(document.querySelector('.m[data-id="3"] mark.kw')).backgroundColor),'rgba(0, 0, 0, 0)','switched off: no marks')
await p.evaluate(()=>import('/js/views/predict.js').then(m=>m.setAssistPref('keys',true)))

// 8. Without Workers AI on the server: nothing asked, nothing shown.
await p.evaluate(async()=>{const{state}=await import('/js/store.js');state.assist=false;const t=document.querySelector('.composer textarea');t.value='';t.dispatchEvent(new Event('input',{bubbles:true}))})
const m=asked.length;await p.keyboard.type('明天');await sleep(700);assert.equal(asked.length,m);assert.equal((await field()).shown,'')

assert.deepEqual(errors,[])
console.log('PASS: a reply in an empty focused field and the rest of the sentence after the caret, laid exactly over the field; typing through it, Tab / tap take it, Escape puts it away; never in the live preview until taken; switched off or no AI: nothing asked; key words marked in sent messages, the other side\'s preview plain and kept when they arrive, the setting hides them at once')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
