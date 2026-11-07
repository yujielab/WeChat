// Smart panels: no button and no sheet — when something in recent one-to-one conversations is timely (a
// ride under way, a plan in the next hours, someone just home), cards made from it come to the top of
// the chat list by themselves ("For you"), and are gone when nothing is. Chips choose between the kinds
// there are (Plans, People, Photos, Weather), the most pressing leading; each card has what and when on
// top, dashed rules around its rows, and one action at the foot (Open chat, Directions, Say hi, View
// photo). A conversation that moved on is read again; a card opens its conversation; the conversation's
// details show its own cards; searching hides the panel; Settings can switch it off. The local server
// has no Workers AI, so its answers are stood in for here; accounts and conversations are real.
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
  const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display}),200)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const A=await account(`na_${uniq}`,'Ming'),B=await account(`nb_${uniq}`,'Hong'),C=await account(`nc_${uniq}`,'Gang')
const r1=(await api(A,'/api/dm',{username:`nb_${uniq}`})).room,r2=(await api(A,'/api/dm',{username:`nc_${uniq}`})).room
await api(C,'/api/messages',{room:r2.id,type:'text',text:'Hiking this weekend?'})
await api(B,'/api/messages',{room:r1.id,type:'text',text:'Landed in Hangzhou'})
const peer=r=>({id:r.peer.id,display:r.peer.display,avatar:''})
const now=Date.now()
const TIMELY={
  city:'Hangzhou',
  upcoming:[{what:'Parcel arrives',at:now+90*MIN,ref:null}],
  ride:{stage:'waiting',plate:'ZA·12345',car:'White BYD',pickup:now+8*MIN,dropoff:null,to:'West Lake',ref:null},
  home:{state:'out',at:now-20*MIN,ref:null},
  meetup:{place:'Starbucks West Lake',at:now+150*MIN,ref:null},
  mood:{label:'tired',note:'Long day at work',ref:null},
  photos:[{ref:'p1',url:PHOTO,at:now-30*MIN,place:'The beach',reading:'Sand at sunset'}],
  summary:'She is in Hangzhou and wants to meet this afternoon',
  ongoing:[],
  likes:['hotpot','cats'],dislikes:['coriander'],hobbies:['photography']
}
// Nothing pressing: what they like and a recap only.
const QUIET={city:'',upcoming:[],ride:null,home:null,meetup:null,mood:null,photos:[],summary:'Talked about books',ongoing:[],likes:['books'],dislikes:[],hobbies:[]}
const WEATHER={temp:24,unit:'c',text:'Clear',symbol:'sun',isDay:true,high:25,low:15,next:{kind:'sunset',time:'17:28'},place:'Hangzhou',who:'Hong',room:r1.id}
let insight=QUIET,gang=null,refreshed=0,asked=0
// Workers AI's part, stood in for: Hong's conversation has been read; Gang's has something new.
await A.route('**/api/insights**',async route=>{
  const url=new URL(route.request().url())
  if(url.pathname==='/api/insights/refresh'){refreshed++;await sleep(300);gang={...QUIET,mood:{label:'happy',note:'Sun is out for the weekend',ref:null},summary:'Asked you to go hiking this weekend',likes:['hiking']};return route.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,room:r2.id,peer:peer(r2),stale:false,at:Date.now(),insight:gang})})}
  asked++
  const only=url.searchParams.get('room')
  await sleep(200)
  const rooms=[{room:r1.id,peer:peer(r1),stale:false,at:now,insight},{room:r2.id,peer:peer(r2),stale:!gang,at:gang?now:0,insight:gang}]
  return route.fulfill({contentType:'application/json',body:JSON.stringify({ok:true,enabled:true,rooms:only?rooms.filter(r=>r.room===only):rooms,weather:only?null:WEATHER})})
})
const setAssist=on=>A.evaluate(async on=>{const{state}=await import('/js/store.js');state.assist=on;window.dispatchEvent(new Event('insights-pref'))},on)
const panel=A.locator('.pane-list .ip')
await A.reload();await A.waitForSelector('.row')

// 1. No entry button anywhere, and no panel where the server can't read.
assert.equal(await A.locator('.list-insights').count(),0,'no way in: it comes by itself')
await setAssist(false);await sleep(400)
assert.equal(await panel.isVisible(),false,'not without the server reading')
// 2. Nothing timely (a recap, what they like): asked, read the conversation that moved on, still nothing shown.
await setAssist(true)
await sleep(1200)
assert.ok(asked>=1,'asked what is known');assert.equal(refreshed,1,'the conversation that moved on was read')
assert.equal(await panel.isVisible(),false,'nothing timely: no panel')
await A.screenshot({path:path.join(OUT,'65-insights-quiet.png')})

// 3. Something timely: the panel comes to the top of the list, the most pressing kind leading.
insight=TIMELY
await A.evaluate(async()=>(await import('/js/views/insights.js')).setInsightsPref(true))
await panel.waitFor()
assert.equal(await A.locator('.ip-title').textContent(),'For you')
const chips=()=>A.evaluate(()=>[...document.querySelectorAll('.pane-list .ip-chip')].map(c=>`${c.textContent}${c.getAttribute('aria-selected')==='true'?'*':''}`))
assert.deepEqual(await chips(),['Plans*','People','Photos','Weather'])
const kinds=()=>A.evaluate(()=>[...document.querySelectorAll('.pane-list .ip-cards > .ip-card')].map(c=>c.dataset.kind))
assert.deepEqual(await kinds(),['ride','meetup','upcoming','home'],'a ride, then the plan, then what happens soonest, then out')
// Above the chats, under the notes.
const order=await A.evaluate(()=>{const s=document.querySelector('.pane-list .list-scroll');const i=el=>[...s.children].indexOf(el);return [i(s.querySelector('.notes')),i(s.querySelector('.ip')),i(s.querySelector('.list-section'))]})
assert.ok(order[0]<order[1]&&order[1]<order[2],`order ${order}`)
// A card: what and when on top, rows between dashed rules, one action.
const card=A.locator('.ip-card[data-kind="ride"]')
assert.equal(await card.locator('.ip-state').textContent(),'Ride')
assert.match(await card.locator('.ip-when').textContent(),/^in [78] min$/)
assert.deepEqual(await card.locator('.ip-label').allTextContents(),['Hong','To West Lake'])
assert.equal((await card.locator('.ip-value').allTextContents())[0],'ZA·12345')
assert.equal(await card.locator('.ip-act').textContent(),'Open chat')
assert.equal(await card.locator('.ip-rows').evaluate(e=>getComputedStyle(e).borderTopStyle),'dashed')
assert.equal(await A.locator('.ip-card[data-kind="meetup"] .ip-act').textContent(),'Directions')
assert.equal(await A.locator('.ip-card[data-kind="home"] .ip-act').textContent(),'Say hi')
// The cards sit side by side and scroll sideways; the page doesn't.
const geo=await A.evaluate(()=>{const c=document.querySelector('.pane-list .ip-cards');return{sw:c.scrollWidth,cw:c.clientWidth,doc:document.documentElement.scrollWidth,vw:innerWidth}})
assert.ok(geo.sw>geo.cw,'cards scroll sideways');assert.ok(geo.doc<=geo.vw,'no page overflow')
await sleep(500);await A.screenshot({path:path.join(OUT,'66-insights-panel.png')})

// 4. Chips choose the kind: People (Gang's, read), Photos, Weather.
await A.locator('.ip-chip[data-group="people"]').click()
assert.deepEqual(await chips(),['Plans','People*','Photos','Weather'])
assert.deepEqual(await kinds(),['mood','mood','summary','summary','likes','likes'])
assert.ok((await A.locator('.ip-card[data-kind="mood"] .ip-label').allTextContents()).includes('In a good mood'),'Gang\'s, once read')
await A.locator('.ip-chip[data-group="photos"]').click()
assert.equal(await A.locator('.ip-card[data-kind="photo"] .ip-thumb').getAttribute('src'),PHOTO)
assert.equal(await A.locator('.ip-card[data-kind="photo"] .ip-act').textContent(),'View photo')
await A.locator('.ip-chip[data-group="weather"]').click()
assert.equal(await A.locator('.ip-weather .ip-state').textContent(),'Hangzhou')
assert.deepEqual(await A.locator('.ip-weather .ip-value').allTextContents(),['24°C','17:28'])
assert.equal(await A.locator('.ip-weather .ip-act').count(),0)
await sleep(400);await A.screenshot({path:path.join(OUT,'67-insights-weather.png')})

// 5. Dark.
await A.locator('.ip-chip[data-group="plans"]').click()
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(500)
await A.screenshot({path:path.join(OUT,'68-insights-dark.png')})
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('light'));await sleep(200)

// 6. Searching keeps to its results.
await A.locator('.search-pill input').focus();await sleep(300)
assert.equal(await panel.isVisible(),false,'hidden while searching')
await A.locator('.search-cancel').click();await sleep(300)
assert.equal(await panel.isVisible(),true,'back after searching')

// 7. A card opens its conversation.
await A.locator('.ip-card[data-kind="ride"] .ip-act').click()
await A.waitForFunction(id=>import('/js/store.js').then(({state})=>state.open===id),r1.id)
await A.waitForSelector('.thread:not([hidden]) .msgs .m')

// 8. Its details show its own cards, without "Open chat".
await A.locator('.thread:not([hidden]) .thread-info').click();await A.locator('.art-body .ins-section .ip-card[data-kind]').first().waitFor()
const own=await A.evaluate(()=>[...document.querySelectorAll('.art-body .ins-section .ip-card')].map(c=>c.dataset.kind))
assert.deepEqual(own,['ride','meetup','upcoming','home','mood','photo','summary','likes'],'only Hong\'s')
assert.ok(!(await A.locator('.art-body .ins-section .ip-act').allTextContents()).includes('Open chat'))
await sleep(300);await A.screenshot({path:path.join(OUT,'69-insights-details.png')})

// 9. Switched off in Settings: gone.
await A.evaluate(async()=>(await import('/js/views/insights.js')).setInsightsPref(false))
await A.reload();await A.waitForSelector('.row')
await setAssist(true);await sleep(800)
assert.equal(await panel.isVisible(),false)

assert.deepEqual(errors,[])
console.log('PASS: smart panels: no entry button; not without the server reading; nothing timely, no panel (the conversation that moved on still read); timely, at the top of the list under the notes with the most pressing kind leading; a card\'s state, time, dashed rows and action; cards scroll sideways; chips choose People, Photos, Weather; dark; hidden while searching; a card opens its conversation; its details show only its cards without Open chat; off in Settings, gone')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
