// A conversation's (and a call's) backdrop never stops on a hard edge at the system's status column: with
// the column beside the page (iOS 27.2: the page a column narrower than the screen, on a touch screen) or in
// it (a right safe area), the backdrop blurs and fades out into the page's own colour as it reaches that
// edge. Where there's no column (a desktop window) or the edge meets the other column, it runs to the edge.
// Pixels are sampled from screenshots. npm run dev:e2e; node tools/e2e/backdrop-edges.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-backdrop-edges')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
// The Duo's inner screen with the status column beside the page: 951pt of page on a 1041pt screen, by touch.
const duo={viewport:{width:951,height:669},screen:{width:1041,height:669},isMobile:true,hasTouch:true}
async function page(opts,label){
  const ctx=await browser.newContext({locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:1,...opts})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${label}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE);return p
}
const A=await page(duo,'duo')
await A.evaluate(async b=>fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)}),{username:`ea_${uniq}`,password:'hunter22',display:'小明'})
const B=await page({viewport:{width:466,height:678}},'peer')
await B.evaluate(async b=>fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)}),{username:`eb_${uniq}`,password:'hunter22',display:'小红'})
const json=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const room=(await json(A,'/api/dm',{username:`eb_${uniq}`})).room.id
await json(B,'/api/messages',{room,type:'text',text:'在吗'})
// A saturated red photo as the chat backdrop (and for calls), so the fade can be measured.
const url=await A.evaluate(async()=>{const c=document.createElement('canvas');c.width=64;c.height=64;const g=c.getContext('2d');g.fillStyle='#e01010';g.fillRect(0,0,64,64);const blob=await new Promise(r=>c.toBlob(r,'image/png'));const res=await fetch('/api/media/upload?kind=bg&name=bg',{method:'POST',headers:{'content-type':'image/png'},body:blob});return (await res.json()).url})
await json(A,'/api/prefs',{chat:url,call:url})

const open=async p=>{await p.reload();await p.waitForSelector(`.row[data-id="${room}"]`);await p.locator(`.row[data-id="${room}"] .row-inner`).click();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await p.waitForFunction(()=>document.querySelector('.thread:not([hidden]) .thread-backdrop')?.dataset.backdrop==='photo');await sleep(600)}
// How red a pixel is: 1 the backdrop itself (washed), 0 the page's white.
const pixel=async(p,x,y)=>{const buf=await p.screenshot({clip:{x,y,width:1,height:1}});return p.evaluate(async b64=>{const img=new Image();img.src='data:image/png;base64,'+b64;await img.decode();const c=document.createElement('canvas');c.width=1;c.height=1;const g=c.getContext('2d');g.drawImage(img,0,0);return [...g.getImageData(0,0,1,1).data]},buf.toString('base64'))}
const redness=async(p,x,y)=>{const px=await pixel(p,x,y);return Math.max(0,Math.min(1,(255-px[1])/200))}
// On the dark call screen: how red against black.
const callRedness=async(p,x,y)=>{const [r,g]=await pixel(p,x,y);return Math.max(0,Math.min(1,(r-g)/110))}
const themeColor=p=>p.evaluate(()=>document.querySelector('meta[name="theme-color"]').getAttribute('content'))
const edges=async p=>p.evaluate(()=>{const r=document.querySelector('.thread:not([hidden]) .thread-backdrop').getBoundingClientRect();return{left:r.left,right:r.right,top:r.top,bottom:r.bottom}})

// 1. The Duo: the column beside the page is recognised, and the backdrop fades out into it.
await open(A)
assert.equal(await A.evaluate(()=>document.documentElement.dataset.column),'beside')
let e=await edges(A),y=Math.round((e.top+e.bottom)/2)
const inner=await redness(A,Math.round(e.right-150),y),edge=await redness(A,Math.round(e.right-2),y),mid=await redness(A,Math.round(e.right-30),y)
assert.ok(inner>0.6,'the backdrop itself, away from the edge: '+inner)
assert.ok(edge<0.12,'gone at the edge beside the column: '+edge)
assert.ok(mid>edge&&mid<inner,'fading in between: '+[inner,mid,edge].join(' > '))
// Its other edge meets the list, not the column: no fade there.
assert.ok(await redness(A,Math.round(e.left+3),y)>0.6,'runs to the edge it shares with the list')
await A.screenshot({path:path.join(OUT,'70-edge-fade-duo.png')})

// 2. The call screen fades out into the column the same way.
await A.evaluate(async([room,peer])=>{const{createCalls}=await import('/js/views/call.js');const{state}=await import('/js/store.js');state.calls={...state.calls,enabled:true};window.c=createCalls({socketSend(){},connected:()=>true});window.c.onSignal({t:'call',kind:'invite',room,callId:'edge',media:'audio',from:peer,caller:{id:peer,display:'小红'}})},[room,'x'])
await A.locator('.call .call-backdrop[data-backdrop="photo"]').waitFor();await sleep(600)
const call=await A.evaluate(()=>{const r=document.querySelector('.call .call-backdrop').getBoundingClientRect();return{right:r.right,y:Math.round(r.top+r.height/3)}})
const callRed=await callRedness(A,Math.round(call.right-150),call.y),callEdge=await callRedness(A,Math.round(call.right-2),call.y)
assert.ok(callRed>0.6&&callEdge<0.12,'the call backdrop fades at the column too: '+[callRed,callEdge].join(' > '))
const [r,g,b]=await pixel(A,Math.round(call.right-2),call.y);assert.ok(r+g+b<60,'into the call\'s black')
// …and the column beside the page is as black as the call while it's up, then back.
assert.equal(await themeColor(A),'#000000')
await A.screenshot({path:path.join(OUT,'71-edge-fade-call.png')})
await A.evaluate(()=>document.querySelector('.call .call-btn.hang')?.click());await A.locator('.call').waitFor({state:'detached'}).catch(()=>{})
assert.equal(await themeColor(A),'#ffffff','the column back to the page\'s white')

// 3. A desktop window: no column, the backdrop runs to the edge.
const D=await page({viewport:{width:951,height:669}},'desktop');await D.context().addCookies(await A.context().cookies())
await open(D)
assert.equal(await D.evaluate(()=>document.documentElement.dataset.column),undefined)
e=await edges(D);y=Math.round((e.top+e.bottom)/2)
assert.ok(await redness(D,Math.round(e.right-2),y)>0.6,'no column: to the edge')

// 4. A column in the page (a right safe area), folded: the fade is there too.
const S=await page({viewport:{width:466,height:678}},'safe');await S.context().addCookies(await A.context().cookies())
await S.addInitScript(()=>document.addEventListener('DOMContentLoaded',()=>document.documentElement.style.setProperty('--safe-right','84px')))
await open(S)
e=await edges(S);y=Math.round((e.top+e.bottom)/2)
const sIn=await redness(S,Math.round(e.right-150),y),sEdge=await redness(S,Math.round(e.right-2),y)
assert.ok(sIn>0.6&&sEdge<0.12,'into a safe-area column: '+[sIn,sEdge].join(' > '))
await S.screenshot({path:path.join(OUT,'72-edge-fade-safe-area.png')})

assert.deepEqual(errors,[])
console.log('PASS: with the status column beside the page (touch, page a column narrower than the screen) the conversation backdrop and the call backdrop blur and fade out into it (the column as black as the call while it is up), not on its edge shared with the list; a desktop window runs to the edge; a column in the page (right safe area) fades too')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
