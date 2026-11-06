// The Moments editor (views/moments-editor.js), after the reference: Cancel and Post across the top; the words;
// photos as large cards side by side, each with ×, a pencil (turn, crop, a look) and +ALT; Tag people; who can see
// and comment; Undo and Redo; the tools (photos, camera, a time to share it) and a ring for what's left to write;
// leaving with something written asks first (Cancel, Escape). What it shares: a photo's description (ALT on the
// card, read on a tap, and in the photo's label), friends it's with, comments only for friends (a stranger reads
// so), and one scheduled for later (only its author sees it, marked). Real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/moments-editor.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-moments-editor')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const OUTER={width:466,height:678},INNER={width:951,height:669}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,vp=OUTER){const ctx=await browser.newContext({viewport:vp,locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,isMobile:true,hasTouch:true});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,body===undefined?{}:{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const draw=(p,[w,h],[a,b])=>p.evaluate(async([w,h,a,b])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const g=c.getContext('2d');const gr=g.createLinearGradient(0,0,w,h);gr.addColorStop(0,a);gr.addColorStop(1,b);g.fillStyle=gr;g.fillRect(0,0,w,h);g.fillStyle='rgba(255,255,255,.85)';g.beginPath();g.arc(w*.68,h*.35,Math.min(w,h)*.15,0,7);g.fill();const blob=await new Promise(r=>c.toBlob(r,'image/png'));return[...new Uint8Array(await blob.arrayBuffer())]},[w,h,a,b]).then(x=>Buffer.from(x))

const B=await account(`eb_${uniq}`,'Coisini'),D=await account(`ed_${uniq}`,'Mira'),A=await account(`ea_${uniq}`,'Tokio')
const room=(await api(A,'/api/dm',{username:`eb_${uniq}`})).room.id
await api(A,'/api/messages',{room,type:'text',text:'Morning!'});await api(B,'/api/messages',{room,type:'text',text:'Hey!'})
const bId=(await api(B,'/api/bootstrap')).me.id

// 1. The editor, from the Moments home: Cancel, Post (nothing to post yet), the words, the foot.
await A.reload();await A.waitForSelector('.shell')
await A.locator('.list-moments').click();await A.locator('.moments-home').waitFor();await sleep(500)
await A.locator('.moments-home .mo-head-actions [aria-label="New moment"]').click();await A.locator('.moments-editor').waitFor();await sleep(500)
const ed=A.locator('.moments-editor')
assert.equal(await ed.locator('.me-post').isDisabled(),true);assert.equal(await ed.locator('.me-post').textContent(),'Post')
assert.equal(await ed.locator('.me-text').getAttribute('placeholder'),"What's new?")
assert.equal(await ed.locator('.me-who-label').textContent(),'Everyone can see and comment')
assert.deepEqual(await ed.locator('.me-tools .me-tool').evaluateAll(b=>b.map(x=>x.getAttribute('aria-label'))),['Add photos or a video','Take a photo or video','Schedule'])
assert.equal(await ed.locator('.me-undo').isDisabled(),true)
// The foot stays at the foot of the sheet.
const foot=await A.evaluate(()=>{const d=document.querySelector('.me-dock').getBoundingClientRect(),s=document.querySelector('.moments-editor').getBoundingClientRect();return s.bottom-d.bottom})
assert.ok(foot<=2,'the dock at the foot '+foot)

// 2. Words, and two photos as cards side by side; the ring fills; Undo takes the photos out, Redo puts them back.
await ed.locator('.me-text').fill('Homework done, finally. Physics and English, both chapters.')
assert.equal(await ed.locator('.me-post').isDisabled(),false)
await ed.locator('.me-dock input[type=file]:not([capture])').setInputFiles([{name:'a.png',mimeType:'image/png',buffer:await draw(A,[900,1200],['#e9e4d8','#b9b2a3'])},{name:'b.png',mimeType:'image/png',buffer:await draw(A,[900,1200],['#dfe7ef','#9fb3c8'])}])
await A.waitForFunction(()=>document.querySelectorAll('.me-card').length===2);await sleep(400)
const cards=await ed.locator('.me-card').evaluateAll(c=>c.map(x=>{const r=x.getBoundingClientRect();return{w:Math.round(r.width),h:Math.round(r.height),tools:[...x.querySelectorAll('button')].map(b=>b.getAttribute('aria-label')||b.textContent)}}))
assert.equal(cards[0].tools.join('|'),'Remove photo 1|Edit photo|Add a description');assert.ok(Math.abs(cards[0].w/cards[0].h-0.75)<0.03,'at its own shape '+JSON.stringify(cards[0]))
assert.equal(await ed.locator('.me-ring').getAttribute('aria-label'),`${2000-'Homework done, finally. Physics and English, both chapters.'.length} characters left`)
await A.screenshot({path:path.join(OUT,'1-editor.png')})
await ed.locator('.me-undo').click();await sleep(200);assert.equal(await ed.locator('.me-card').count(),0,'Undo: the photos go')
await ed.locator('.me-redo').click();await sleep(200);assert.equal(await ed.locator('.me-card').count(),2,'Redo: back')
await ed.locator('.me-undo').click();await ed.locator('.me-undo').click();await sleep(200)
assert.equal(await ed.locator('.me-text').inputValue(),'','Undo again: the words go too')
await ed.locator('.me-redo').click();await ed.locator('.me-redo').click();await sleep(300)
assert.equal(await ed.locator('.me-text').inputValue(),'Homework done, finally. Physics and English, both chapters.');assert.equal(await ed.locator('.me-card').count(),2)

// 3. The pencil: turn it and crop it square, in Mono; the card takes its new shape.
await ed.locator('.me-card').first().locator('.me-card-edit').click();await A.locator('.me-edit-sheet').waitFor();await sleep(500)
await A.locator('.me-edit-sheet .me-turn').click();await A.locator('.me-edit-sheet .me-shapes [data-shape="square"]').click();await A.locator('.me-edit-sheet .me-look[data-look="mono"]').click();await sleep(300)
const prev=await A.locator('.me-edit-preview').evaluate(c=>[c.width,c.height]);assert.equal(prev[0],prev[1],'square')
await A.screenshot({path:path.join(OUT,'2-edit-photo.png')})
await A.locator('.me-edit-sheet .me-alt-done').click();await A.locator('.me-edit-sheet').waitFor({state:'detached'});await sleep(400)
const first=await ed.locator('.me-card').first().evaluate(x=>{const r=x.getBoundingClientRect();return r.width/r.height});assert.ok(Math.abs(first-1)<0.03,'the card is square now '+first)

// 4. +ALT: a description for the second photo; the button says so.
await ed.locator('.me-card').nth(1).locator('.me-card-alt').click();await A.locator('.me-alt-text').waitFor();await sleep(300)
await A.locator('.me-alt-text').fill('A worksheet of physics questions about lenses, answers in pencil')
await A.screenshot({path:path.join(OUT,'3-alt.png')})
await A.locator('.me-small-sheet .me-alt-done').click();await sleep(400)
assert.equal(await ed.locator('.me-card').nth(1).locator('.me-card-alt').textContent(),'ALT')

// 5. Tag people: friends to pick from; Coisini.
await ed.locator('.me-tags').click();await A.locator('.me-tag-row').first().waitFor();await sleep(300)
assert.deepEqual(await A.locator('.me-tag-row').evaluateAll(r=>r.map(x=>x.querySelector('b').textContent)),['Coisini'],'only friends')
await A.locator('.me-tag-row').first().click();assert.equal(await A.locator('.me-tag-row').first().getAttribute('aria-checked'),'true')
await A.locator('.me-small-sheet .me-alt-done').click();await sleep(400)
assert.equal(await ed.locator('.me-tags .me-row-label').textContent(),'With Coisini')

// 6. Who can see and comment: everyone sees it, only friends comment.
await ed.locator('.me-who').click();await A.locator('.menu .menu-item:has-text("Only friends can comment")').click()
await A.waitForFunction(()=>document.querySelector('.moments-editor .me-who-label')?.textContent.endsWith('Friends can comment'))
assert.equal(await ed.locator('.me-who-label').textContent(),'Everyone can see · Friends can comment')
await A.screenshot({path:path.join(OUT,'4-ready.png')})

// 7. Leaving asks first: Escape, then Cancel; both kept.
await A.keyboard.press('Escape');await A.locator('.prompt .prompt-btn.main:has-text("Discard")').waitFor()
assert.equal(await A.locator('.prompt .prompt-title').textContent(),'Discard this moment?');await sleep(500)
await A.screenshot({path:path.join(OUT,'4b-discard.png')})
await A.locator('.prompt .prompt-cancel').click();await sleep(300);assert.equal(await A.locator('.moments-editor').count(),1,'Escape asked; kept')
await ed.locator('.me-cancel').click();await A.locator('.prompt .prompt-btn.main:has-text("Discard")').waitFor()
await A.locator('.prompt .prompt-cancel').click();await sleep(300);assert.equal(await A.locator('.moments-editor').count(),1,'Cancel asked; kept')

// 8. Post: it leads the feed — with its description, Coisini, and comments for friends.
await ed.locator('.me-post').click();await A.locator('.moments-editor').waitFor({state:'detached'});await sleep(800)
const top=A.locator('.moments-home .mo-item').first()
assert.match(await top.locator('.mo-caption').textContent(),/Homework done/)
assert.equal(await top.locator('.mo-with').textContent(),'With Coisini')
assert.equal(await top.locator('.mo-slide').nth(1).locator('.mo-photo img').getAttribute('alt'),'A worksheet of physics questions about lenses, answers in pencil')
assert.equal(await top.locator('.mo-slide').nth(1).locator('.mo-photo').getAttribute('aria-label'),'Photo 2 of 2: A worksheet of physics questions about lenses, answers in pencil')
const posted=(await api(A,'/api/moments')).moments[0]
assert.equal(posted.commenting,'friends');assert.deepEqual(posted.tags.map(t=>t.id),[bId]);assert.equal(posted.media[0].w,posted.media[0].h,'the edited photo, square')
// ALT on the photo reads the description.
await top.locator('.mo-track').evaluate(t=>t.scrollTo({left:t.clientWidth,behavior:'instant'}));await sleep(300)
await top.locator('.mo-slide').nth(1).locator('.mo-alt').click();await A.locator('.mo-alt-sheet').waitFor();await sleep(300)
assert.equal(await A.locator('.mo-alt-sheet .mo-alt-text').textContent(),'A worksheet of physics questions about lenses, answers in pencil')
await A.screenshot({path:path.join(OUT,'5-posted.png')})
await A.keyboard.press('Escape');await A.locator('.mo-alt-sheet').waitFor({state:'detached'})
// A stranger sees it, and reads that only friends comment; a friend can.
const forD=(await api(D,`/api/moments/${posted.id}`)).moment;assert.equal(forD.canComment,false)
assert.equal((await api(B,`/api/moments/${posted.id}`)).moment.canComment,true)

// 9. Scheduled: tomorrow at 9; the Post pill says Schedule; only its author sees it, marked.
await A.locator('.moments-home .mo-head-actions [aria-label="New moment"]').click();await A.locator('.moments-editor').waitFor();await sleep(400)
await ed.locator('.me-text').fill('Good morning, future me')
await ed.locator('.me-tool[aria-label="Schedule"]').click();await A.locator('.me-scheduling').waitFor();await sleep(300)
await A.locator('.me-chip:has-text("Tomorrow, 9:00")').click();assert.match(await A.locator('.me-when-summary').textContent(),/^Shares Tomorrow 9:00$/)
await A.screenshot({path:path.join(OUT,'6-schedule.png')})
await A.locator('.me-small-sheet .me-alt-done').click();await sleep(400)
assert.equal(await ed.locator('.me-post').textContent(),'Schedule');assert.equal(await ed.locator('.me-when .me-row-label').textContent(),'Scheduled for Tomorrow 9:00')
await ed.locator('.me-post').click();await A.locator('.moments-editor').waitFor({state:'detached'});await sleep(800)
const planned=A.locator('.moments-home .mo-item.scheduled')
assert.equal(await planned.count(),1);assert.equal(await planned.locator('.mo-scheduled').textContent(),'Scheduled for Tomorrow 9:00')
const plannedId=await planned.getAttribute('data-id')
assert.ok(!(await api(B,'/api/moments')).moments.some(m=>m.id===plannedId),'a friend does not see it yet')

// 10. Comments for friends only, as a stranger sees it.
await D.reload();await D.waitForSelector('.shell');await D.locator('.list-moments').click();await D.locator(`.mo-item[data-id="${posted.id}"]`).waitFor();await sleep(400)
assert.equal(await D.locator(`.mo-item[data-id="${posted.id}"] .mo-closed`).textContent(),"Only Tokio's friends can comment")
assert.equal(await D.locator(`.mo-item[data-id="${posted.id}"] .mo-reply`).count(),0)

// 11. The open screen, dark: the editor in the middle.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'))
await A.setViewportSize(INNER);await sleep(800)
await A.locator('.moments-home .mo-head-actions [aria-label="New moment"]').click();await A.locator('.moments-editor').waitFor();await sleep(600)
await ed.locator('.me-text').fill('Dark and wide');await ed.locator('.me-dock input[type=file]:not([capture])').setInputFiles([{name:'c.png',mimeType:'image/png',buffer:await draw(A,[1600,900],['#2b5876','#4e4376'])}]);await A.waitForFunction(()=>document.querySelectorAll('.me-card').length===1);await sleep(500)
const box=await A.locator('.moments-editor').boundingBox();assert.ok(Math.abs(box.x+box.width/2-INNER.width/2)<=1,'in the middle '+JSON.stringify(box))
await A.screenshot({path:path.join(OUT,'7-open-dark.png')})

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: the editor (Cancel, Post only with something to post, What\'s new?, who can see and comment, Undo/Redo, photos/camera/schedule, the dock at the foot); two photos as cards at their own shape with ×, pencil and +ALT; the ring for what\'s left; Undo and Redo through words and photos; the pencil turns, crops square and gives a look; a description; Tag people from friends only; comments for friends; Escape and Cancel ask first; posted: its description on the photo and read from ALT, with Coisini, comments for friends (a stranger reads so, a friend may comment); scheduled for tomorrow 9:00, Post says Schedule, only its author sees it, marked; the open screen, dark')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
