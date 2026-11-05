// The page can't be pulled out of shape. On a touch screen: a pinch and a double tap leave the scale at 1
// (and with the protections taken away the same pinch does zoom, so this test would catch their loss);
// Ctrl/⌘ + wheel and the zoom keys, Safari's gesture events, a file or link dropped on the page, a link or
// picture dragged out of it and a container scrolled off its place are all refused — while text still drops
// into the field, and a photo opened in the viewer still pinches inside the viewer.
// npm run dev:e2e; node tools/e2e/steady.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-steady')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)
const touch={viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,hasTouch:true,isMobile:true}

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function account(username,display,opts=touch,prepare){
  const ctx=await browser.newContext(opts)
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  if(prepare)await prepare(p)
  await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display}),200)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const scale=p=>p.evaluate(()=>window.visualViewport.scale)
// Two fingers on the glass, or a trackpad pinch: both reach the browser's own zoom.
const pinch=async(p,x,y,factor,source='touch')=>{const cdp=await p.context().newCDPSession(p);await cdp.send('Input.synthesizePinchGesture',{x,y,scaleFactor:factor,relativeSpeed:400,gestureSourceType:source});await cdp.detach();await sleep(500)}
const doubleTap=async(p,x,y)=>{const cdp=await p.context().newCDPSession(p);await cdp.send('Input.synthesizeTapGesture',{x,y,tapCount:2,gestureSourceType:'touch'});await cdp.detach();await sleep(400)}

const A=await account(`sa_${uniq}`,'小明'),B=await account(`sb_${uniq}`,'小红',{viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block'})
const room=(await api(A,'/api/dm',{username:`sb_${uniq}`})).room.id
await api(B,'/api/messages',{room,type:'text',text:'在吗'})
await A.reload();await A.waitForSelector('.row')

// 1. The viewport asks for a fixed scale.
const meta=await A.evaluate(()=>document.querySelector('meta[name="viewport"]').content)
for(const token of ['initial-scale=1','minimum-scale=1','maximum-scale=1','user-scalable=no','viewport-fit=cover'])assert.ok(meta.includes(token),`${token} in ${meta}`)

// 2. A pinch, and a double tap, on the list and in a conversation: still at scale 1, nothing moved.
const rect0=await A.evaluate(()=>{const r=document.querySelector('.shell').getBoundingClientRect();return[r.left,r.top,r.width,r.height]})
await pinch(A,233,330,2.6);await pinch(A,233,330,2.6,'mouse');assert.equal(await scale(A),1,'a pinch on the list');await doubleTap(A,233,330);assert.equal(await scale(A),1,'a double tap on the list')
await A.locator('.row .row-inner').first().tap();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(600)
await pinch(A,233,330,2.6);await pinch(A,233,330,2.6,'mouse');assert.equal(await scale(A),1,'a pinch in the conversation');await doubleTap(A,233,300);assert.equal(await scale(A),1,'a double tap in the conversation')
assert.deepEqual(await A.evaluate(()=>{const r=document.querySelector('.shell').getBoundingClientRect();return[r.left,r.top,r.width,r.height]}),rect0,'the layout did not move')
await A.screenshot({path:path.join(OUT,'74-after-pinch.png')})

// 2b. Without the protections the same pinch does zoom — so the check above would notice losing them.
const bare=await account(`sc_${uniq}`,'小刚',touch,async p=>{
  await p.route('**/',async r=>{const res=await r.fetch();await r.fulfill({response:res,body:(await res.text()).replace(/<meta name="viewport"[^>]*>/,'<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">')})})
  await p.route('**/css/base.css',async r=>{const res=await r.fetch();await r.fulfill({response:res,body:(await res.text()).replace('* { touch-action: pan-x pan-y; }','')})})
  await p.route('**/js/ui/steady.js',r=>r.fulfill({contentType:'text/javascript',body:'export function initSteady(){}'}))
})
await pinch(bare,233,330,2.6,'mouse')
assert.ok(await scale(bare)>1.2,'unprotected, the same pinch zooms: '+await scale(bare))
await bare.context().close()

// 3. Ctrl/⌘ + wheel, the zoom keys and Safari's gesture events are cancelled; plain scrolling and typing are not.
await A.evaluate(()=>{window.__seen=[];for(const type of['wheel','keydown'])window.addEventListener(type,e=>window.__seen.push([type,e.key||'',e.ctrlKey||e.metaKey,e.defaultPrevented]),{passive:true})})
const cancelled=await A.evaluate(()=>({
  ctrlWheel:!document.body.dispatchEvent(new WheelEvent('wheel',{ctrlKey:true,deltaY:-100,bubbles:true,cancelable:true})),
  plainWheel:!document.body.dispatchEvent(new WheelEvent('wheel',{deltaY:-100,bubbles:true,cancelable:true})),
  gesture:['gesturestart','gesturechange','gestureend'].map(t=>!document.body.dispatchEvent(new Event(t,{bubbles:true,cancelable:true})))
}))
assert.deepEqual(cancelled,{ctrlWheel:true,plainWheel:false,gesture:[true,true,true]})
await A.keyboard.press('Control+Equal');await A.keyboard.press('Control+Minus');await A.keyboard.press('Control+0');await A.keyboard.press('Meta+Equal')
await A.locator('.thread:not([hidden]) .composer textarea').click();await A.keyboard.type('+1')
// (Pressing Control or Meta is a keydown too; it's the combinations that count.)
const keys=await A.evaluate(()=>window.__seen.filter(s=>s[0]==='keydown'&&!['Control','Meta'].includes(s[1])))
assert.deepEqual(keys.filter(k=>k[2]).map(k=>k[3]),[true,true,true,true],'every zoom shortcut cancelled')
assert.deepEqual(keys.filter(k=>!k[2]&&k[1]==='+').map(k=>k[3]),[false],'a plus typed is not')
assert.equal(await A.locator('.thread:not([hidden]) .composer textarea').inputValue(),'+1')

// 4. A file or link dropped on the page doesn't navigate; text dropped into the field is left alone; a link or
// picture can't be dragged out.
const drops=await A.evaluate(()=>{
  const dt=new DataTransfer();dt.items.add(new File(['x'],'a.png',{type:'image/png'}))
  const text=new DataTransfer();text.setData('text/plain','hello')
  const fire=(target,type,data)=>!target.dispatchEvent(new DragEvent(type,{bubbles:true,cancelable:true,dataTransfer:data}))
  const field=document.querySelector('.thread:not([hidden]) .composer textarea'),bubble=document.querySelector('.thread:not([hidden]) .msgs .m')
  const link=document.createElement('a');link.href='https://example.com';link.textContent='x';document.body.append(link)
  const out={fileOnBubble:fire(bubble,'drop',dt),fileOverBubble:fire(bubble,'dragover',dt),fileOnField:fire(field,'drop',dt),textOnBubble:fire(bubble,'drop',text),textOnField:fire(field,'drop',text),dragLink:fire(link,'dragstart',text),dragField:fire(field,'dragstart',text)}
  link.remove();return out
})
assert.deepEqual(drops,{fileOnBubble:true,fileOverBubble:true,fileOnField:true,textOnBubble:true,textOnField:false,dragLink:true,dragField:false})

// 5. A container that is never meant to scroll is put back.
const crept=await A.evaluate(async()=>{
  const app=document.getElementById('app'),tall=document.createElement('div');tall.style.cssText='position:absolute;left:0;top:0;width:10px;height:4000px;pointer-events:none';app.append(tall)
  app.scrollTop=120;await new Promise(r=>setTimeout(r,200));const after=app.scrollTop;tall.remove();return after
})
assert.equal(crept,0,'the app is back in place')
const pageCrept=await A.evaluate(async()=>{window.scrollTo(0,60);await new Promise(r=>setTimeout(r,200));return[window.scrollX,window.scrollY]})
assert.deepEqual(pageCrept,[0,0])

// 6. The photo viewer still pinches — inside the viewer; the page stays at scale 1.
const PHOTO=await A.evaluate(()=>{const c=document.createElement('canvas');c.width=1200;c.height=800;const g=c.getContext('2d');g.fillStyle='#4a7';g.fillRect(0,0,1200,800);g.fillStyle='#fff';g.fillRect(560,0,80,800);return c.toDataURL('image/png')})
await A.evaluate(async src=>{const{openViewer}=await import('/js/views/viewer.js');openViewer({kind:'image',src,fullSrc:src,w:1200,h:800})},PHOTO)
await A.locator('.viewer .viewer-media').waitFor();await sleep(900)
const zoomOf=()=>A.evaluate(()=>{const m=new DOMMatrix(getComputedStyle(document.querySelector('.viewer-media')).transform);return Math.hypot(m.a,m.b)})
const k0=await zoomOf()
const cdp=await A.context().newCDPSession(A)
const tp=(a,b)=>[{x:233-a,y:339,id:1},{x:233+a,y:339,id:2}].slice(0,b)
await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:tp(30,2)})
for(let i=1;i<=10;i++){await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:tp(30+i*14,2)});await sleep(16)}
await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});await sleep(600)
const k1=await zoomOf()
assert.ok(k1>k0*1.4,`the photo zoomed in the viewer: ${k0} → ${k1}`)
assert.equal(await scale(A),1,'and the page did not')
await A.screenshot({path:path.join(OUT,'75-viewer-pinched.png')})
// A double tap zooms the photo back out (or in), again inside the viewer.
await doubleTap(A,233,339);await sleep(500)
const k2=await zoomOf()
assert.ok(Math.abs(k2-k1)/k1>0.15,`a double tap changes the photo's zoom: ${k1} → ${k2}`)
assert.equal(await scale(A),1,'the page still at 1')

assert.deepEqual(errors,[])
console.log('PASS: the viewport is fixed at scale 1; a pinch and a double tap leave the page where it was (and zoom it without the protections); Ctrl/⌘+wheel, Ctrl/⌘ with + − 0 and Safari\'s gestures are cancelled while a typed "+" is not; a file dropped anywhere and a link dragged out are refused while text still drops into the field; the app and the page are put back if scrolled; the photo viewer still pinches and double-taps, inside the viewer only')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
