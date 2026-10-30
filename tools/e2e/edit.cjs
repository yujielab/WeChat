// Editing a sent message: from its long-press menu, the field takes its words (a strip says what is being
// edited, the button saves, the message is marked) and whatever was being written comes back afterwards.
// Saving rewrites it in place at once, for both sides, without anything new to read; "已编辑" under it shows
// each wording. Nothing typed into an edit reaches the other side's live preview; Escape or ✕ cancels; a
// failed save puts the message back; only your own text messages, within 15 minutes, can be edited.
// Two real accounts against the local server. npm run dev:e2e; node tools/e2e/edit.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-edit')
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
const A=await account(`ea_${uniq}`,'小明'),B=await account(`eb_${uniq}`,'小红')
const room=(await api(A,'/api/dm',{username:`eb_${uniq}`})).room.id
await api(B,'/api/messages',{room,type:'text',text:'几点见？'})
const sent=(await api(A,'/api/messages',{room,type:'text',text:'明天三点见'})).msg
const open=async p=>{await p.reload();await p.waitForSelector('.row');await p.locator('.row .row-inner').first().click();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(400)}
await open(A);await open(B)
const bubble=(p,text)=>p.locator(`.thread:not([hidden]) .m .bubble:has-text("${text}")`)
const field=p=>p.locator('.thread:not([hidden]) .composer textarea')
const texts=p=>p.evaluate(()=>[...document.querySelectorAll('.thread:not([hidden]) .msgs > .m:not(.ghost-row)')].map(n=>n.querySelector('.bubble')?.textContent.trim()+(n.querySelector('.m-edited')?' ·已编辑':'')))
const menuItems=async(p,text)=>{await bubble(p,text).click({button:'right'});await p.locator('.menu.on').waitFor();const items=await p.locator('.menu.on .menu-item .label').allTextContents();return items}
const closeMenu=async p=>{await p.keyboard.press('Escape');await sleep(300)}
// The other side's live preview of what A types.
const ghost=()=>B.evaluate(()=>document.querySelector('.thread:not([hidden]) .ghost-row .bubble')?.textContent||'')

// 1. Only your own text messages offer 编辑.
assert.ok(!(await menuItems(B,'明天三点见')).includes('编辑'),'not someone else\'s');await closeMenu(B)
assert.ok(!(await menuItems(A,'几点见？')).includes('编辑'),'not theirs, from your side either');await closeMenu(A)

// 2. Something half-written stays aside while editing.
await field(A).click();await field(A).type('草稿还在',{delay:230})
await B.waitForFunction(()=>document.querySelector('.thread:not([hidden]) .ghost-row .bubble')?.textContent==='草稿还在')
assert.ok((await menuItems(A,'明天三点见')).includes('编辑'))
await A.locator('.menu.on .menu-item:has-text("编辑")').first().click();await sleep(400)
const mode=await A.evaluate(()=>{const c=document.querySelector('.thread:not([hidden]) .composer');return{editing:c.classList.contains('editing'),quote:c.querySelector('.composer-edit-quote')?.textContent,value:c.querySelector('textarea').value,label:c.querySelector('.composer-action').getAttribute('aria-label'),focused:document.activeElement===c.querySelector('textarea'),marked:Boolean(document.querySelector('.thread:not([hidden]) .m.editing .bubble'))}})
assert.deepEqual(mode,{editing:true,quote:'明天三点见',value:'明天三点见',label:'保存修改',focused:true,marked:true})
await B.waitForFunction(()=>!document.querySelector('.thread:not([hidden]) .ghost-row .bubble')?.textContent).catch(()=>{})
assert.equal(await ghost(),'','what was being typed no longer shows on the other side')
await A.screenshot({path:path.join(OUT,'61-editing.png')})

// 3. Typing into the edit never reaches the other side's live preview; saving rewrites it for both, at once.
await field(A).press('End');for(let i=0;i<3;i++)await field(A).press('Backspace')
await field(A).type('四点见，门口');await sleep(1500)
assert.equal(await ghost(),'','an edit is not a live preview')
await field(A).press('Enter');await sleep(150)
assert.deepEqual((await texts(A)).slice(-1),['明天四点见，门口 ·已编辑'],'at once on this side')
assert.equal(await field(A).inputValue(),'草稿还在','the draft is back')
assert.equal(await A.locator('.thread:not([hidden]) .composer.editing').count(),0)
await B.waitForFunction(()=>[...document.querySelectorAll('.thread:not([hidden]) .m .bubble')].some(b=>b.textContent.includes('明天四点见，门口')))
assert.deepEqual(await texts(B),['几点见？','明天四点见，门口 ·已编辑'],'rewritten in place on the other side')
assert.equal(await B.evaluate(async id=>(await import('/js/store.js')).state.chats.get(id).last.text,room),'明天四点见，门口','the list preview follows')
assert.equal(await B.locator('.thread:not([hidden]) .thread-title .sub.typing').count(),0,'and they are no longer shown typing')
await B.screenshot({path:path.join(OUT,'62-edited.png')})

// 4. 已编辑 shows each wording.
await B.locator('.thread:not([hidden]) .m-edited').click();await B.locator('.sheet .edit-history').waitFor();await sleep(400)
assert.deepEqual(await B.locator('.sheet .edit-text').allTextContents(),['明天三点见','明天四点见，门口'])
assert.match(await B.locator('.sheet .edit-version.now .edit-when').textContent(),/^现在/)
await B.screenshot({path:path.join(OUT,'63-edit-history.png')})
await B.keyboard.press('Escape');await sleep(400)

// 5. Escape (or ✕) cancels: the message as it was, the draft back.
await menuItems(A,'明天四点见，门口');await A.locator('.menu.on .menu-item:has-text("编辑")').first().click();await sleep(300)
await field(A).type('不要了');await A.keyboard.press('Escape');await sleep(300)
assert.deepEqual((await texts(A)).slice(-1),['明天四点见，门口 ·已编辑']);assert.equal(await field(A).inputValue(),'草稿还在')
await menuItems(A,'明天四点见，门口');await A.locator('.menu.on .menu-item:has-text("编辑")').first().click();await sleep(300)
await A.locator('.composer-edit-cancel').click();await sleep(300)
assert.equal(await A.locator('.thread:not([hidden]) .composer.editing').count(),0);assert.equal(await field(A).inputValue(),'草稿还在')

// 6. A save the server refuses puts the message back, and says why.
await A.route('**/api/edit',r=>r.fulfill({status:400,contentType:'application/json',body:JSON.stringify({ok:false,error:'发出超过 15 分钟的消息不能再编辑'})}))
await menuItems(A,'明天四点见，门口');await A.locator('.menu.on .menu-item:has-text("编辑")').first().click();await sleep(300)
await field(A).fill('改不了');await field(A).press('Enter');await sleep(600)
assert.deepEqual((await texts(A)).slice(-1),['明天四点见，门口 ·已编辑'],'put back')
assert.ok(await A.locator('.toast:has-text("15 分钟")').count(),'and why')
await A.unroute('**/api/edit')

// 7. After a reload, still rewritten; past 15 minutes, no 编辑 (the server holds the same rule).
await open(A);await open(B)
assert.deepEqual(await texts(B),['几点见？','明天四点见，门口 ·已编辑'])
await A.evaluate(async id=>{const{state}=await import('/js/store.js');for(const t of state.threads.values()){const m=t.byId.get(id);if(m)m.ts-=16*60*1000}},sent.id)
assert.ok(!(await menuItems(A,'明天四点见，门口')).includes('编辑'),'too late to edit');await closeMenu(A)

assert.deepEqual(errors,[])
console.log('PASS: only your own text messages offer 编辑; editing puts its words in the field with a strip and ✓, the message marked, the draft set aside and back afterwards; nothing typed into an edit reaches the live preview; saving rewrites it at once for both sides, with the list preview, and 已编辑 shows each wording; Escape and ✕ cancel; a refused save puts it back and says why; after a reload it stays rewritten; past 15 minutes there is no 编辑')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
