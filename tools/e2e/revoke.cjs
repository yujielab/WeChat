// A message taken back leaves no empty bubble: where it was, a note says who took it back ("你撤回了一条消息"
// for the sender, "<name>撤回了一条消息" for the others), on both sides, at once and after a reload. Taking one back
// adds nothing to the unread count and moves nothing up the list; the list's preview changes only if it was
// the last message, and an unread one taken back is no longer counted.
// Two real accounts against the local server. npm run dev:e2e; node tools/e2e/revoke.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-revoke')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function account(username,display){
  const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE)
  const status=await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display})
  assert.equal(status,200,'registered '+username)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const A=await account(`ra_${uniq}`,'小明'),B=await account(`rb_${uniq}`,'小红')
const room=(await api(A,'/api/dm',{username:`rb_${uniq}`})).room.id
for(const text of ['第一条','要撤回的这条','第三条'])await api(A,'/api/messages',{room,type:'text',text})
// What a conversation shows: its bubbles' texts and its notes, in order.
const shown=p=>p.evaluate(()=>[...document.querySelectorAll('.thread:not([hidden]) .msgs > .m, .thread:not([hidden]) .msgs > .sys')].map(n=>n.classList.contains('sys')?`[${n.textContent}]`:n.querySelector('.bubble')?.textContent.trim()||'(空气泡)'))
const open=async p=>{await p.locator('.row').first().click();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(400)}
await A.reload();await A.waitForSelector('.row');await open(A)
await B.reload();await B.waitForSelector('.row');await open(B)
assert.deepEqual(await shown(B),['第一条','要撤回的这条','第三条'])

// 1. Taken back from the long-press menu: a note where the bubble was, on both sides, at once.
await A.locator('.m .bubble:has-text("要撤回的这条")').click({button:'right'});await A.locator('.menu-item:has-text("撤回")').click()
await sleep(800)
assert.deepEqual(await shown(A),['第一条','[你撤回了一条消息]','第三条'],'the sender sees a note, no empty bubble')
assert.deepEqual(await shown(B),['第一条','[小明撤回了一条消息]','第三条'],'the other side too')
await B.screenshot({path:path.join(OUT,'49-revoked.png')})

// 2. On the list, taking back an older message moves nothing; the last one's preview follows; an unread
// one taken back is no longer counted.
await B.locator('.thread:not([hidden]) [data-item="back"]').click();await sleep(400)
const row=()=>B.evaluate(()=>{const r=document.querySelector('.row');const c=r.querySelector('.row-count');return{preview:r.querySelector('.row-preview').textContent,unread:c.hidden?0:Number(c.textContent)}})
assert.deepEqual(await row(),{preview:'第三条',unread:0})
const first=(await A.evaluate(()=>import('/js/store.js').then(({state})=>[...state.threads.values()][0].list.find(m=>m.text==='第一条').id)))
await api(A,'/api/revoke',{id:first});await sleep(600)
assert.deepEqual(await row(),{preview:'第三条',unread:0},'an older one taken back: the row stays as it was')
const fourth=(await api(A,'/api/messages',{room,type:'text',text:'第四条'})).msg.id;await sleep(600)
assert.deepEqual(await row(),{preview:'第四条',unread:1})
await api(A,'/api/revoke',{id:fourth});await sleep(1200)
assert.deepEqual(await row(),{preview:'小明撤回了一条消息',unread:0},'the last one taken back: its preview follows, and nothing is left to read')

// 3. After a reload, the notes are still notes.
await B.reload();await B.waitForSelector('.row');await open(B)
assert.deepEqual(await shown(B),['[小明撤回了一条消息]','[小明撤回了一条消息]','第三条','[小明撤回了一条消息]'])
assert.deepEqual(errors,[])
console.log('PASS: a message taken back leaves a note saying who took it back where its bubble was, never an empty bubble, for both sides, at once and after a reload; nothing new is counted or moved up the list; the preview follows only the last message; an unread one taken back is no longer counted')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
