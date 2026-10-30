// Smart notifications: the sparkles button at the top of the list opens cards made from what recent
// conversations say (a ride, a plan, getting home, things that will happen, mood, something going on, a
// photo's place, a summary, likes) and the weather where they are — ten kinds. The three most pressing
// stand and the rest stack beneath; the stack opens into the whole list (现在) and closes again. A
// conversation with something new is read while you look; a card opens its conversation; the
// conversation's details show its own cards; Settings can switch it off. The local server has no Workers
// AI, so its answers are stood in for here; accounts and conversations are real.
// npm run dev:e2e; node tools/e2e/insights.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-insights')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)
const MIN=60e3,HOUR=60*MIN,DAY=24*HOUR
const PHOTO='data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><defs><linearGradient id="g" x2="0" y2="1"><stop offset="0" stop-color="#f6a"/><stop offset="1" stop-color="#36c"/></linearGradient></defs><rect width="8" height="8" fill="url(#g)"/></svg>')

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function account(username,display){
  const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display}),200)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const A=await account(`na_${uniq}`,'小明'),B=await account(`nb_${uniq}`,'小红'),C=await account(`nc_${uniq}`,'小刚')
const r1=(await api(A,'/api/dm',{username:`nb_${uniq}`})).room,r2=(await api(A,'/api/dm',{username:`nc_${uniq}`})).room
await api(C,'/api/messages',{room:r2.id,type:'text',text:'周末去爬山吗'})
await api(B,'/api/messages',{room:r1.id,type:'text',text:'我到杭州了'})
const peer=r=>({id:r.peer.id,display:r.peer.display,avatar:''})
const now=Date.now()
const INSIGHT={
  city:'杭州',
  upcoming:[{what:'快递送到',at:now+90*MIN,ref:null}],
  ride:{stage:'等车',plate:'浙A·12345',car:'白色比亚迪',pickup:now+8*MIN,dropoff:null,to:'西湖',ref:null},
  home:{state:'出门',at:now-20*MIN,ref:null},
  meetup:{place:'星巴克（西湖店）',at:now+150*MIN,ref:null},
  mood:{label:'疲惫',note:'说今天加班好累',ref:null},
  photos:[{ref:'p1',url:PHOTO,at:now-30*MIN,place:'海边',reading:'日落时分的沙滩'}],
  summary:'她到杭州了，约你下午在星巴克见',
  ongoing:[{what:'经期',since:now-DAY,until:null,note:'前天说的',ref:null}],
  likes:['火锅','猫'],dislikes:['香菜'],hobbies:['摄影']
}
const WEATHER={temp:24,unit:'c',text:'晴',symbol:'sun',isDay:true,high:25,low:15,next:{kind:'sunset',time:'17:28'},place:'杭州',who:'小红',room:r1.id}
let refreshed=0
// Workers AI's part, stood in for: 小红's conversation has been read; 小刚's has something new.
await A.route('**/api/insights**',async route=>{
  const url=new URL(route.request().url())
  if(url.pathname==='/api/insights/refresh'){refreshed++;await sleep(500);return route.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,room:r2.id,peer:peer(r2),stale:false,at:Date.now(),insight:{city:'',upcoming:[],ride:null,home:null,meetup:null,mood:{label:'开心',note:'说周末终于放晴了',ref:null},photos:[],summary:'约你周末去爬山',ongoing:[],likes:['爬山'],dislikes:[],hobbies:['徒步']}})})}
  const only=url.searchParams.get('room')
  await sleep(350)
  const rooms=[{room:r1.id,peer:peer(r1),stale:false,at:now,insight:INSIGHT},{room:r2.id,peer:peer(r2),stale:refreshed===0,at:0,insight:null}]
  return route.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,enabled:true,rooms:only?rooms.filter(r=>r.room===only):rooms,weather:only?null:WEATHER})})
})
await A.reload();await A.waitForSelector('.row')

// 1. Where the server can't read (no Workers AI), no way in; where it can, the sparkles at the top of the list.
const offer=on=>A.evaluate(async on=>{const{state}=await import('/js/store.js');state.assist=on;window.dispatchEvent(new Event('insights-pref'))},on)
await offer(false);assert.equal(await A.locator('.list-insights').isVisible(),false,'not offered without the server reading')
await offer(true);assert.equal(await A.locator('.list-insights').isVisible(),true)
await A.locator('.list-insights').click()

// 2. Shapes while it loads, then the three most pressing stand, the rest stacked beneath.
await A.locator('.sheet .ins-skeleton').first().waitFor()
await A.locator('.sheet .ins-card[data-kind]').first().waitFor()
const standing=()=>A.evaluate(()=>[...document.querySelectorAll('.sheet .ins-list > .ins-card')].map(c=>c.dataset.kind))
assert.deepEqual(await standing(),['ride','meetup','upcoming'],'a ride, then the plan, then what happens soonest')
assert.ok(await A.locator('.sheet .ins-more').count(),'the rest stacked')
// 3. 小刚's conversation has something new: read now, while you look.
assert.match(await A.locator('.sheet .ins-status').textContent(),/正在读最近的 1 个聊天/)
await A.locator('.sheet .ins-status').waitFor({state:'hidden'})
assert.equal(refreshed,1)
// A card's sentence as read (a picture's initial isn't part of it).
const words=(sel,root='.sheet')=>A.evaluate(sel=>[...document.querySelectorAll(sel)].map(n=>{const c=n.cloneNode(true);c.querySelectorAll('.avatar').forEach(a=>a.remove());return c.textContent}),`${root} ${sel}`)
const line=async kind=>(await words(`.ins-card[data-kind="${kind}"] .ins-line`))[0]
assert.match(await line('ride'),/^接车 小红 的车 浙A·12345 · 白色比亚迪 · 约 \d\d:\d\d 到上车点$/)
assert.match(await line('meetup'),/^赴约 今天 \d\d:\d\d 在 星巴克（西湖店） 见 小红$/)
assert.match(await A.locator('.sheet .ins-card[data-kind="meetup"] .ins-sub').textContent(),/^还有 (2|3) 小时$/)
// 4. The weather where she is.
assert.equal(await A.locator('.sheet .ins-weather-head').textContent(),'杭州 · 小红那边')
assert.deepEqual(await A.locator('.sheet .ins-tile').allTextContents(),['晴24°C','日落17:28'])
await sleep(300);await A.screenshot({path:path.join(OUT,'65-insights-stack.png')})

// 5. The stack opens into the whole list — every kind — and closes again.
await A.locator('.sheet .ins-more').click();await sleep(500)
assert.equal(await A.locator('.sheet .ins-head').textContent(),'现在')
const kinds=await A.evaluate(()=>[...document.querySelectorAll('.sheet .ins-list > .ins-card')].map(c=>c.dataset.kind))
assert.deepEqual(kinds,['ride','meetup','upcoming','home','mood','mood','ongoing','photo','summary','summary','likes','likes'])
assert.deepEqual([...new Set(kinds)].length+1,10,'nine kinds of card and the weather')
for(const [kind,re] of [['home',/^出门 小红 \d\d:\d\d 出门了$/],['upcoming',/^提醒 快递送到 · 今天 \d\d:\d\d$/],['mood',/^关心 小红 似乎有些累$/],['ongoing',/^留意 小红 经期 · 第 2 天$/],['photo',/^看看 小红 的照片像是在 海边$/],['summary',/^回顾 小红：她到杭州了，约你下午在星巴克见$/],['likes',/^记住 小红 喜欢 火锅、猫；不喜欢 香菜$/]])assert.match(await line(kind),re,kind)
assert.ok((await words('.ins-card[data-kind="mood"] .ins-line')).includes('关心 小刚 心情不错'),'小刚\'s, once read')
assert.equal(await A.locator('.sheet .ins-thumb').getAttribute('src'),PHOTO)
await A.screenshot({path:path.join(OUT,'66-insights-open.png'),fullPage:false})
await A.locator('.sheet .ins-thumb').scrollIntoViewIfNeeded();await sleep(200);await A.screenshot({path:path.join(OUT,'67-insights-open-lower.png')})
await A.locator('.sheet .ins-fold').scrollIntoViewIfNeeded();await A.locator('.sheet .ins-fold').click();await sleep(300)
assert.deepEqual(await standing(),['ride','meetup','upcoming'],'closed again')

// 6. Dark.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(400)
await A.screenshot({path:path.join(OUT,'68-insights-dark.png')})
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('light'));await sleep(200)

// 7. A card opens its conversation.
await A.locator('.sheet .ins-card[data-kind="meetup"]').click()
await A.waitForFunction(id=>import('/js/store.js').then(({state})=>state.open===id),r1.id)
await A.waitForSelector('.thread:not([hidden]) .msgs .m');await A.locator('.sheet').waitFor({state:'detached'})

// 8. Its details show its own cards.
await A.locator('.thread:not([hidden]) .thread-title').click();await A.locator('.art-body .ins-section .ins-card[data-kind]').first().waitFor()
const own=await A.evaluate(()=>[...document.querySelectorAll('.art-body .ins-section .ins-card')].map(c=>c.dataset.kind))
assert.deepEqual(own,['ride','meetup','upcoming','home','mood','ongoing','photo','summary','likes'],'only 小红\'s')
await sleep(300);await A.screenshot({path:path.join(OUT,'69-insights-details.png')})

// 9. Switched off in Settings: no way in, nothing in the details.
await A.evaluate(async()=>(await import('/js/views/insights.js')).setInsightsPref(false))
await A.reload();await A.waitForSelector('.row')
await offer(true)
assert.equal(await A.locator('.list-insights').isVisible(),false)

assert.deepEqual(errors,[])
console.log('PASS: smart notifications: the sparkles at the top of the list (only where the server can read); shapes while loading; ride, plan and what happens soonest stand, the rest stacked; a conversation with something new read while you look; the weather where she is; the stack opens into all ten kinds (现在) and closes; dark; a card opens its conversation; its details show only its cards; off in Settings, no way in')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
