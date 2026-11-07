// The Messages list after the Instagram inbox (views/chatList.js, views/people.js): with no chats yet, a line with
// Start; notes along the top (yours first to share one, a friend's with a reply that lands in your chat with them,
// yours reaching a friend live); Requests at the end of the filters with how many wait, Accept and the count going;
// Suggested ("Tap to chat") opening a chat with a contact you had none with; People you may know (friends of
// friends with how many in common; Add turning into Requested and reaching them; × setting one aside for good;
// See all); search hiding all of it and Cancel bringing it back; the open screen, dark.
// Real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/inbox.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-inbox')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const OUTER={width:466,height:678},INNER={width:951,height:669}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,vp=OUTER){const ctx=await browser.newContext({viewport:vp,locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,isMobile:true,hasTouch:true});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body,method)=>p.evaluate(async([url,body,method])=>(await fetch(url,{method:method||(body===undefined?'GET':'POST'),headers:{'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})})).json(),[url,body,method])
const idOf=async p=>(await api(p,'/api/bootstrap')).me.id
const talk=async(x,y,yid,text='Hey there, long time!')=>{const room=(await api(x,'/api/dm',{user:yid})).room.id;await api(x,'/api/messages',{room,type:'text',text:'hi'});await api(y,'/api/messages',{room,type:'text',text});return room}

const A=await account(`ia_${uniq}`,'Tokio')
// 1. No chats yet: a line with Start (to a new chat), your note to share, Requests with nothing waiting.
await A.locator('.list-start').waitFor();await sleep(500)
assert.equal(await A.locator('.list-start').textContent(),'Your chats appear here. Start')
assert.deepEqual(await A.locator('.notes .note').evaluateAll(n=>n.map(b=>b.getAttribute('aria-label'))),['Share a note'])
assert.equal(await A.locator('.note-mine .note-text').textContent(),'Share a thought…')
assert.equal(await A.locator('.list-requests').getAttribute('aria-label'),'Requests');assert.equal(await A.locator('.requests-count').isHidden(),true)
await A.screenshot({path:path.join(OUT,'1-start.png')})
await A.locator('.list-start-link').click();await A.locator('.sheet:has-text("New chat")').waitFor();await sleep(400)
assert.equal(await A.locator('.sheet .cell:has-text("Invite friends")').count(),1,'Invite friends in New chat too')
await A.keyboard.press('Escape');await A.locator('.sheet:has-text("New chat")').waitFor({state:'detached'})

// People: B a friend with a note; C and E friends of B's; D asks to add A; F a contact of A's with no chat.
const B=await account(`ib_${uniq}`,'Coisini'),C=await account(`ic_${uniq}`,'Mira'),D=await account(`id_${uniq}`,'Alani'),E=await account(`ie_${uniq}`,'Yueee'),F=await account(`if_${uniq}`,'Sofie')
const [a,b,c,d,e,f]=await Promise.all([A,B,C,D,E,F].map(idOf))
const roomAB=await talk(A,B,b);await talk(B,C,c);await talk(B,E,e)
await api(A,'/api/contacts/add',{user:f});await api(F,'/api/contacts/accept',{user:a})
await api(D,'/api/contacts/add',{user:a})
await api(B,'/api/note',{text:'Off to the mountains 🏔️ back Sunday'})
await A.reload();await A.waitForSelector('.shell');await A.locator('.people-discover:not([hidden])').waitFor();await sleep(600)

// 2. The list: notes, the filters with Requests (1 waiting), the chat, Suggested, People you may know.
assert.deepEqual(await A.locator('.notes .note').evaluateAll(n=>n.map(b=>b.querySelector('.note-name').textContent)),['Your note','Coisini'])
assert.equal(await A.locator(`.note[data-user="${b}"] .note-text`).textContent(),'Off to the mountains 🏔️ back Sunday')
assert.equal(await A.locator('.list-requests').getAttribute('aria-label'),'Requests, 1 waiting');assert.equal(await A.locator('.requests-count').textContent(),'1')
assert.deepEqual(await A.locator('.people-suggested .person-row').evaluateAll(r=>r.map(x=>x.querySelector('.person-text').textContent)),['SofieTap to chat'])
const known=await A.locator('.people-discover .person-row[data-user]').evaluateAll(r=>r.map(x=>[x.dataset.user,x.querySelector('.person-sub').textContent]))
assert.deepEqual(known.slice(0,2).map(x=>x[1]),['1 mutual friend','1 mutual friend'],'friends of friends first');assert.deepEqual(known.slice(0,2).map(x=>x[0]).sort(),[c,e].sort())
for(const id of [a,b,d,f])assert.ok(!known.some(x=>x[0]===id),'never yourself, a friend, someone asking, or a contact')
assert.equal(await A.locator('.invite-card').count(),1)
// In order down the page: notes, filters, the chat, Suggested, People you may know.
const order=await A.evaluate(()=>['.notes','.list-section','.rows .row','.people-suggested','.people-discover'].map(s=>document.querySelector(s).getBoundingClientRect().top))
assert.deepEqual([...order].sort((x,y)=>x-y),order,'in order '+JSON.stringify(order))
await A.screenshot({path:path.join(OUT,'2-inbox.png')})

// 3. A friend's note: read it, reply — the reply lands in your chat with them.
await A.locator(`.note[data-user="${b}"]`).click();await A.locator('.note-sheet').waitFor();await sleep(400)
assert.equal(await A.locator('.note-sheet .note-text').textContent(),'Off to the mountains 🏔️ back Sunday')
await A.screenshot({path:path.join(OUT,'3-note.png')})
await A.locator('.note-reply-input').fill('Have fun up there!');await A.locator('.note-reply-send').click()
await A.locator('.note-sheet').waitFor({state:'detached'});await A.waitForSelector('.thread:not([hidden])');await sleep(600)
const last=(await api(B,`/api/messages?room=${roomAB}`)).messages.at(-1)
assert.equal(last.body,'Replied to your note “Off to the mountains 🏔️ back Sunday”\nHave fun up there!')
await A.locator('.thread:not([hidden]) [data-item="back"]').click();await sleep(600)

// 4. Your note: write it, share it; a friend sees it arrive, live.
await B.reload();await B.waitForSelector('.shell');await sleep(500)
await A.locator('.note-mine').click();await A.locator('.note-sheet .note-input').waitFor();await sleep(300)
assert.equal(await A.locator('.note-share').isDisabled(),true,'nothing to share yet')
await A.locator('.note-input').fill('Coffee anyone?');assert.equal(await A.locator('.note-count').textContent(),'14/60')
await A.screenshot({path:path.join(OUT,'4-your-note.png')})
await A.locator('.note-share').click();await A.locator('.note-sheet').waitFor({state:'detached'});await sleep(400)
assert.equal(await A.locator('.note-mine .note-text').textContent(),'Coffee anyone?')
await B.locator(`.note[data-user="${a}"]`).waitFor({timeout:8000})
assert.equal(await B.locator(`.note[data-user="${a}"] .note-text`).textContent(),'Coffee anyone?','live, for a friend')
assert.equal(await C.evaluate(async a=>(await (await fetch('/api/notes')).json()).notes.some(n=>n.user.id===a),a),false,'not for a stranger')

// 5. Requests: who wants to add you; Accept, and the count goes.
await A.locator('.list-requests').click();await A.locator('.requests-sheet').waitFor();await sleep(400)
assert.deepEqual(await A.locator('.requests-sheet .person-row').evaluateAll(r=>r.map(x=>x.dataset.user)),[d])
await A.screenshot({path:path.join(OUT,'5-requests.png')})
await A.locator('.requests-sheet .person-action:has-text("Accept")').click();await A.locator('.requests-sheet .people-empty').waitFor();await sleep(300)
assert.match(await A.locator('.requests-sheet .people-empty').textContent(),/No requests/)
await A.keyboard.press('Escape');await A.locator('.requests-sheet').waitFor({state:'detached'})
assert.equal(await A.locator('.requests-count').isHidden(),true);assert.equal(await A.locator('.list-requests').getAttribute('aria-label'),'Requests')
assert.equal((await api(D,'/api/contacts')).contacts.find(x=>x.id===a).state,'accepted','D is a contact now')

// 6. Suggested: Tap to chat — a chat with Sofie, and she's no longer suggested.
await A.locator(`.people-suggested .person-row[data-user="${f}"] .person-main`).click();await A.waitForSelector('.thread:not([hidden])');await sleep(400)
assert.match(await A.locator('.thread:not([hidden]) .thread-title').textContent(),/Sofie/)
await A.locator('.thread:not([hidden]) [data-item="back"]').click()
await A.waitForFunction(f=>!document.querySelector(`.people-suggested .person-row[data-user="${f}"]`),f,{timeout:8000})

// 7. People you may know: Add (Requested, and it reaches them); × sets one aside for good; See all.
await A.locator(`.people-discover .person-row[data-user="${c}"] .person-action`).click();await sleep(500)
assert.equal(await A.locator(`.people-discover .person-row[data-user="${c}"] .person-action`).textContent(),'Requested')
assert.equal((await api(C,'/api/contacts')).contacts.find(x=>x.id===a)?.state,'pending_in','the request reached her')
await A.locator(`.people-discover .person-row[data-user="${e}"] .person-dismiss`).click()
await A.waitForFunction(e=>!document.querySelector(`.people-discover .person-row[data-user="${e}"]`),e);await sleep(400)
assert.ok(!(await api(A,'/api/people')).discover.some(x=>x.id===e),'set aside on the server too')
await A.locator('.invite-card .person-dismiss').click();await sleep(200);assert.equal(await A.locator('.invite-card').count(),0,'the invite card, hidden')
if(await A.locator('.people-all:not([hidden])').count()){await A.locator('.people-all').click();await A.locator('.people-all-sheet').waitFor();await sleep(300);assert.ok(await A.locator('.people-all-sheet .person-row').count()>5);await A.keyboard.press('Escape');await A.locator('.people-all-sheet').waitFor({state:'detached'})}

// 8. Search hides it all; Cancel brings it back.
await A.locator('.search-pill input').click();await sleep(400)
assert.deepEqual(await A.evaluate(()=>['.notes','.list-section','.people'].map(s=>document.querySelector(s).hidden)),[true,true,true])
await A.locator('.search-cancel').click();await sleep(500)
assert.deepEqual(await A.evaluate(()=>['.notes','.list-section','.people'].map(s=>document.querySelector(s).hidden)),[false,false,false])
// Filters other than All: no people under them.
await A.locator('.filter-tab[data-filter="unread"]').click();await sleep(300);assert.equal(await A.evaluate(()=>document.querySelector('.people').hidden),true)
await A.locator('.filter-tab[data-filter="all"]').click();await sleep(300)

// 9. The open screen, dark.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'))
await A.setViewportSize(INNER);await sleep(900)
assert.equal(await A.locator('.list-requests').isVisible(),true,'Requests, with the filters a menu')
await A.screenshot({path:path.join(OUT,'6-open-dark.png')})

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: no chats yet, a line with Start; notes along the top, a friend\'s read and replied to into your chat, yours shared and reaching a friend live and not a stranger; Requests with how many wait, Accept and the count goes; Suggested opens a chat and leaves the list; People you may know, friends of friends first with what you share, Add becomes Requested and reaches them, × for good, the invite card set aside, See all; search hides it all and Cancel brings it back; other filters without people; the open screen, dark')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
