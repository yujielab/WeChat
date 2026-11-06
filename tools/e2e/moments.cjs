// Moments (views/moments.js, src/hub.js): a dot on the way in while a friend has shared something new; the home
// feed (the name in large type with New moment, Your moments and Close; a row of people — you first, to share, a
// ring round a friend with something new, a badge on someone you've not talked to; each moment as a card with the
// pictures edge to edge, several swiping one at a time with 1/3 above and dots below, a video playing without sound
// while it's in view); someone you've not talked to: their moments for everyone and not the rest, Suggested for you
// and a Message pill that opens a chat with them; a double tap likes; a comment; a photo opens; their page from
// the people row; a new moment for Friends, and one for Everyone, each seen by whom it's for; your page from the
// heading, with Posts and Media, deleting; a friend sharing while the feed is open; a friend's page from the chat's
// details with Message; dark; both screens. Three real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/moments.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-moments')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const OUTER={width:466,height:678},INNER={width:951,height:669}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,vp){const ctx=await browser.newContext({viewport:vp,locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,isMobile:true,hasTouch:true});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,body===undefined?{}:{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const status=(p,url)=>p.evaluate(async url=>(await fetch(url)).status,url)
// A picture drawn in the page, as bytes (for the file picker) or uploaded as a moment's photo; a second of video.
const draw=(p,[w,h],[a,b])=>p.evaluate(async([w,h,a,b])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const g=c.getContext('2d');const gr=g.createLinearGradient(0,0,w,h);gr.addColorStop(0,a);gr.addColorStop(1,b);g.fillStyle=gr;g.fillRect(0,0,w,h);g.fillStyle='rgba(255,255,255,.8)';g.beginPath();g.arc(w*.68,h*.35,Math.min(w,h)*.15,0,7);g.fill();const blob=await new Promise(r=>c.toBlob(r,'image/png'));return[...new Uint8Array(await blob.arrayBuffer())]},[w,h,a,b]).then(x=>Buffer.from(x))
const uploadPhoto=async(p,size,colors)=>{const bytes=[...await draw(p,size,colors)];return p.evaluate(async([bytes,w,h])=>{const r=await fetch(`/api/media/upload?kind=moment&w=${w}&h=${h}`,{method:'POST',headers:{'content-type':'image/png'},body:new Uint8Array(bytes)});return{url:(await r.json()).url,type:'image',w,h}},[bytes,...size])}
const uploadVideo=p=>p.evaluate(async()=>{const c=document.createElement('canvas');c.width=640;c.height=360;const g=c.getContext('2d');const rec=new MediaRecorder(c.captureStream(24),{mimeType:'video/webm'});const parts=[];rec.ondataavailable=e=>parts.push(e.data);rec.start();const t0=performance.now();await new Promise(done=>{const tick=()=>{const t=(performance.now()-t0)/1000;g.fillStyle=`hsl(${200+t*60} 70% 45%)`;g.fillRect(0,0,640,360);g.fillStyle='#fff';g.beginPath();g.arc(120+t*400,180,40,0,7);g.fill();if(t<1.2)requestAnimationFrame(tick);else done()};tick()});rec.stop();await new Promise(r=>rec.onstop=r);const blob=new Blob(parts,{type:'video/webm'});const r=await fetch('/api/media/upload?kind=moment&w=640&h=360',{method:'POST',headers:{'content-type':'video/webm'},body:blob});return{url:(await r.json()).url,type:'video',w:640,h:360}})

const C=await account(`mc_${uniq}`,'Mira',OUTER)
const B=await account(`mb_${uniq}`,'Coisini',OUTER)
const A=await account(`ma_${uniq}`,'Tokio',OUTER)
// A and B have written to each other: friends. Mira is someone A has never talked to.
const A_ID=(await api(A,'/api/bootstrap')).me.id
const room=(await api(A,'/api/dm',{username:`mb_${uniq}`})).room.id
await api(A,'/api/messages',{room,type:'text',text:'Morning!'})
await api(B,'/api/messages',{room,type:'text',text:'Did you see my sunrise?'})
const hidden=(await api(C,'/api/moments',{text:'Only for my friends',audience:'friends'})).moment
const trip=(await api(C,'/api/moments',{text:'Three days in the mountains — the light up there is something else. Day one: the lake. Day two: the ridge. Day three: home, slowly, by the long road.',media:[await uploadPhoto(C,[1080,1350],['#355c7d','#c06c84']),await uploadPhoto(C,[1080,1350],['#2a9d8f','#e9c46a']),await uploadPhoto(C,[1080,1350],['#264653','#e76f51'])]})).moment
const clip=(await api(B,'/api/moments',{text:'Clip from the trail',media:[await uploadVideo(B)]})).moment
const sunrise=(await api(B,'/api/moments',{text:'Sunrise on the ridge this morning ☀️',media:[await uploadPhoto(B,[1600,1000],['#f6a35b','#6a4c93'])]})).moment
assert.equal(hidden.audience,'friends');assert.equal(trip.audience,'everyone','for everyone unless you say')

// 1. A friend shared something since the last look: a dot on the way in.
await A.reload();await A.waitForSelector('.shell')
await A.waitForFunction(()=>document.querySelector('.list-moments')?.classList.contains('fresh'),null,{timeout:8000})
assert.equal(await A.locator('.list-moments').getAttribute('aria-label'),'Moments, new from friends')

// 2. The home: the name in large type and three round buttons; the people; the cards.
await A.locator('.list-moments').click();await A.locator('.moments-home .mo-item').first().waitFor();await sleep(700)
// (Everyone's moments for everyone are in the feed: those of earlier runs too. Only this run's people count.)
const ours=[A_ID,sunrise.user.id,trip.user.id]
const home=await A.evaluate(ours=>{const q=s=>document.querySelector('.moments-home '+s);const all=s=>[...document.querySelectorAll('.moments-home '+s)],our=s=>all(s).filter(x=>ours.includes(x.dataset.user));return{
  word:q('.mo-wordmark').textContent,buttons:all('.mo-head-actions button').map(b=>b.getAttribute('aria-label')),
  people:our('.mo-person').map(b=>({label:b.querySelector('.mo-person-name').textContent,ring:b.querySelector('.mo-ring').classList.contains('fresh'),badge:b.querySelector('.mo-badge')?.className.replace('mo-badge ','')||null})),
  cards:our('.mo-item').map(c=>({id:c.dataset.id,by:c.querySelector('.mo-by').textContent,sub:c.querySelector('.mo-sub').textContent,pill:!!c.querySelector('.mo-message')}))}},ours)
assert.equal(home.word,'Moments');assert.deepEqual(home.buttons,['New moment','Your moments','Close'])
assert.deepEqual(home.people,[{label:'Your moment',ring:false,badge:'mo-badge-plus'},{label:'Coisini',ring:true,badge:null},{label:'Mira',ring:true,badge:'mo-badge-person-plus'}],'you, then who has something new')
assert.deepEqual(home.cards.map(c=>c.id),[sunrise.id,clip.id,trip.id],'newest first; Mira\'s moment for friends is not here')
assert.deepEqual(home.cards[0],{id:sunrise.id,by:'Coisini',sub:`@mb_${uniq}`,pill:false})
assert.deepEqual(home.cards[2],{id:trip.id,by:'Mira',sub:'Suggested for you',pill:true},'someone you\'ve not talked to: Suggested, and a Message pill')
assert.equal(await A.evaluate(()=>document.querySelector('.list-moments').classList.contains('fresh')),false,'seen: the dot goes')
// The pictures edge to edge, at their own shape (1600×1000).
const shape=await A.locator(`.mo-item[data-id="${sunrise.id}"] .mo-media`).evaluate(m=>{const r=m.getBoundingClientRect(),s=m.closest('.sheet').getBoundingClientRect();return{ratio:r.width/r.height,left:r.left-s.left,right:s.right-r.right}})
assert.ok(Math.abs(shape.ratio-1.6)<0.02&&shape.left<=1&&shape.right<=1,'edge to edge at 1.6:1 '+JSON.stringify(shape))
await A.screenshot({path:path.join(OUT,'1-home.png')})

// 3. A video plays, without sound, while it's in view; the sound is one tap.
const video=A.locator(`.mo-item[data-id="${clip.id}"]`)
await video.scrollIntoViewIfNeeded();await sleep(900)
const v=await video.locator('video').evaluate(v=>({paused:v.paused,muted:v.muted}))
assert.deepEqual(v,{paused:false,muted:true},'playing, without sound')
assert.equal(await video.locator('.mo-sound').getAttribute('aria-label'),'Unmute')
await video.locator('.mo-sound').click()
assert.equal(await video.locator('video').evaluate(v=>v.muted),false);assert.equal(await video.locator('.mo-sound').getAttribute('aria-label'),'Mute')
await video.locator('.mo-sound').click()
await A.screenshot({path:path.join(OUT,'2-video.png')})

// 4. Several photos: one at a time, 1/3 above and dots below; the words cut to two lines with "more".
const trips=A.locator(`.mo-item[data-id="${trip.id}"]`)
await trips.scrollIntoViewIfNeeded();await sleep(300)
assert.equal(await trips.locator('.mo-slide').count(),3);assert.equal(await trips.locator('.mo-index').textContent(),'1/3')
await trips.locator('.mo-track').evaluate(t=>t.scrollTo({left:t.clientWidth,behavior:'instant'}));await sleep(300)
assert.equal(await trips.locator('.mo-index').textContent(),'2/3');assert.deepEqual(await trips.locator('.mo-pips i').evaluateAll(p=>p.map(i=>i.classList.contains('on'))),[false,true,false])
assert.equal(await trips.locator('.mo-more-btn').isVisible(),true,'more to read')
await A.screenshot({path:path.join(OUT,'3-carousel.png')})
await trips.locator('.mo-more-btn').click();assert.equal(await trips.locator('.mo-clamp').evaluate(c=>c.classList.contains('open')),true)
// What A may see of Mira: her moments for everyone, and their pictures; not the one for her friends.
assert.equal(await status(A,trip.media[0].url),200);assert.equal(await status(A,`/api/moments/${hidden.id}`),404)

// 5. A double tap likes it (a heart swells), and stays liked; a comment; a tap opens the photo.
const sun=A.locator(`.mo-item[data-id="${sunrise.id}"]`)
await sun.scrollIntoViewIfNeeded();await sun.locator('.mo-slide').dblclick();await sleep(500)
assert.equal(await sun.locator('.mo-like').getAttribute('aria-pressed'),'true');assert.equal(await sun.locator('.mo-like .mo-count-n').textContent(),'1')
await sun.locator('.mo-reply-input').fill('Gorgeous! Where is this?');await sun.locator('.mo-reply-input').press('Enter');await sleep(500)
assert.equal(await sun.locator('.mo-comments').textContent(),'Tokio Gorgeous! Where is this?');assert.equal(await sun.locator('.mo-talk .mo-count-n').textContent(),'1')
const kept=(await api(A,`/api/moments/${sunrise.id}`)).moment;assert.equal(kept.liked,true);assert.equal(kept.comments.length,1)
await sun.locator('.mo-slide').click();await A.locator('.viewer').waitFor();await sleep(400);await A.keyboard.press('Escape');await A.locator('.viewer').waitFor({state:'detached'})
assert.equal(await A.locator('.moments-home').count(),1,'Escape closed the photo, not the feed')

// 6. Mira's page, from the people row: her moments for everyone, Message.
await A.locator(`.moments-home .mo-person[data-user="${trip.user.id}"]`).click();await A.locator('.moments-profile .mo-item').first().waitFor();await sleep(500)
assert.equal(await A.locator('.moments-profile .mo-name').textContent(),'Mira')
assert.deepEqual(await A.locator('.moments-profile .mo-pill').allTextContents(),['Share profile','Message'])
assert.equal(await A.locator('.moments-profile .mo-counts').textContent(),"1 PostYou've not talked yet")
assert.deepEqual(await A.locator('.moments-profile .mo-item').evaluateAll(c=>c.map(x=>x.dataset.id)),[trip.id])
assert.equal(await A.locator('.moments-profile .mo-close').getAttribute('aria-label'),'Back')
await A.screenshot({path:path.join(OUT,'4-stranger.png')})
await A.locator('.moments-profile .mo-close').click();await A.locator('.moments-profile').waitFor({state:'detached'})
assert.equal(await A.locator(`.moments-home .mo-person[data-user="${trip.user.id}"] .mo-ring`).evaluate(r=>r.classList.contains('fresh')),false,'looked at: the ring goes')

// 7. Message, from her moment: a chat with her, over everything — and still none of what's only for her friends.
await A.locator(`.mo-item[data-id="${trip.id}"] .mo-message`).click()
await A.locator('.moments-page').waitFor({state:'detached'});await A.waitForSelector('.thread:not([hidden])');await sleep(400)
assert.match(await A.locator('.thread:not([hidden]) .thread-title').textContent(),/Mira/,'a chat with her')
assert.equal((await api(A,`/api/moments/user/${trip.user.id}`)).moments.length,1,'opening a chat is not friendship')
await A.screenshot({path:path.join(OUT,'5-chat.png')})
await A.locator('.thread:not([hidden]) [data-item="back"]').click();await sleep(600)

// 8. A new one, for Friends: who can see it is Everyone until you say.
await A.locator('.list-moments').click();await A.locator('.moments-home .mo-item').first().waitFor();await sleep(400)
await A.locator('.moments-home .mo-head-actions [aria-label="New moment"]').click();await A.locator('.mo-composer').waitFor();await sleep(400)
assert.equal(await A.locator('.mo-audience-seg [aria-checked="true"]').textContent(),'Everyone')
await A.locator('.mo-audience-seg [data-audience="friends"]').click()
assert.match(await A.locator('.mo-audience-hint').textContent(),/Only your contacts/)
await A.locator('.mo-composer-body textarea').fill('Weekend roundup: mountains and a sunset')
await A.locator('.mo-composer input[type=file]').setInputFiles([{name:'a.png',mimeType:'image/png',buffer:await draw(A,[1200,900],['#2b5876','#4e4376'])},{name:'b.png',mimeType:'image/png',buffer:await draw(A,[900,1200],['#ee9ca7','#ffdde1'])}])
await A.waitForFunction(()=>document.querySelectorAll('.mo-composer .mo-pick').length===2)
await A.screenshot({path:path.join(OUT,'6-composer.png')})
await A.locator('.mo-post').click();await A.locator('.mo-composer').waitFor({state:'detached'});await sleep(600)
const mine=A.locator('.moments-home .mo-item').first()
assert.equal(await mine.locator('.mo-caption').textContent(),'Tokio Weekend roundup: mountains and a sunset')
assert.equal(await mine.locator('.mo-slide').count(),2);assert.equal(await mine.locator('.mo-for').textContent(),'Friends')
const ownId=await mine.getAttribute('data-id')
const feedIds=async p=>(await api(p,'/api/moments')).moments.map(m=>m.id)
assert.ok((await feedIds(B)).includes(ownId),'a friend sees it');assert.ok(!(await feedIds(C)).includes(ownId),'Mira does not')
// And one for everyone: Mira sees that.
const open=(await api(A,'/api/moments',{text:'Anyone up for a hike Saturday?'})).moment
assert.ok((await feedIds(C)).includes(open.id),'for everyone: Mira sees it')

// 9. Your page, from the heading: Posts and Media, counts, deleting.
await A.locator('.moments-home .mo-me').click();await A.locator('.moments-profile .mo-item').first().waitFor();await sleep(500)
assert.deepEqual(await A.locator('.moments-profile .mo-pill').allTextContents(),['Share profile','Edit profile'])
assert.deepEqual(await A.locator('.moments-profile .mo-tab').evaluateAll(t=>t.map(x=>x.getAttribute('aria-label'))),['Posts','Media'])
assert.equal(await A.locator('.moments-profile .mo-counts').textContent(),'2 Posts1 Friend')
assert.equal(await A.locator('.moments-profile .mo-item .mo-message').count(),0,'no Message on your own')
await A.locator('.moments-profile .mo-tab[data-tab="media"]').click();await A.locator('.mo-card').first().waitFor();await sleep(400)
assert.equal(await A.locator('.mo-card').count(),1);assert.equal(await A.locator('.mo-card .mo-count').textContent(),'2')
await A.locator('.moments-profile .mo-tab[data-tab="posts"]').click();await sleep(600)
await A.locator(`.moments-profile .mo-item[data-id="${open.id}"] .mo-dots`).click();await A.locator('.menu .menu-item:has-text("Delete")').click();await sleep(250)
await A.locator('.menu .menu-item:has-text("Delete")').click();await sleep(600)
assert.equal(await A.locator(`.mo-item[data-id="${open.id}"]`).count(),0,'gone, here and on the home under it')
assert.equal(await A.locator('.moments-profile .mo-counts').textContent(),'1 Post1 Friend')
await A.locator('.moments-profile .mo-close').click();await A.locator('.moments-profile').waitFor({state:'detached'})

// 10. Live: a friend shares something while the feed is open — a pill to see it.
await api(B,'/api/moments',{text:'Back at the trailhead'})
await A.locator('.moments-home .mo-fresh:not([hidden])').waitFor()
await A.locator('.moments-home .mo-fresh').click();await sleep(800)
assert.equal(await A.locator('.moments-home .mo-item').first().locator('.mo-words').textContent(),'Back at the trailhead','newest first')
await A.locator('.moments-home .mo-head-actions [aria-label="Close"]').click();await A.locator('.moments-page').waitFor({state:'detached'})

// 11. A friend's page, from the chat's details: Message leads back to the chat.
await A.locator('.row:has-text("Coisini") .row-inner').click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(500)
await A.locator('.thread:not([hidden]) .thread-title').click();await A.locator('.art-body .cell:has-text("Moments")').waitFor();await sleep(300)
await A.locator('.art-body .cell:has-text("Moments")').click();await A.locator('.moments-profile .mo-item').first().waitFor();await sleep(500)
assert.equal(await A.locator('.moments-profile .mo-name').textContent(),'Coisini')
assert.equal(await A.locator('.moments-profile .mo-counts').textContent(),'3 PostsFriends')
assert.equal(await A.locator('.moments-profile .mo-compose').isHidden(),true,'no new moment on their page')
await A.locator('.moments-profile .mo-pill:has-text("Message")').click();await A.locator('.moments-page').waitFor({state:'detached'});await sleep(500)
assert.equal(await A.locator('.thread:not([hidden])').count(),1)

// 12. Dark, and the open screen.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'))
await A.setViewportSize(INNER);await sleep(700)
await A.locator('.list-moments').click();await A.locator('.moments-home .mo-item').first().waitFor();await sleep(800)
const box=await A.locator('.moments-home').boundingBox()
assert.ok(Math.abs(box.x+box.width/2-INNER.width/2)<=1,'open, in the middle of the screen '+JSON.stringify(box))
await A.screenshot({path:path.join(OUT,'7-open-dark.png')})
await A.evaluate(()=>{document.querySelector('.moments-home .sheet-body').scrollTop=900});await sleep(500)
assert.equal(await A.evaluate(()=>document.querySelector('.moments-home').classList.contains('mo-scrolled')),true,'the heading fills in once the page scrolls')
await A.screenshot({path:path.join(OUT,'8-open-dark-scrolled.png')})

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: a dot while a friend has shared something new, gone once seen; the home feed (the name and three round buttons; you, then people with something new ringed and someone you\'ve not talked to badged; cards edge to edge at their own shape, newest first, a moment for friends only kept from strangers); a video plays without sound in view, sound one tap; three photos one at a time with 1/3 and dots, words with more; a double tap likes and it stays liked, a comment, a tap opens the photo and Escape closes only it; a stranger\'s page from the people row with her moments for everyone and Message; Message on her moment opens a chat over everything, and that is not friendship; a new moment for Friends seen by a friend and not by her, one for Everyone seen by her; your page from the heading with Posts, Media, counts and deleting everywhere at once; a friend sharing while the feed is open shows a pill; a friend\'s page from the chat\'s details with Message back to the chat; dark; centred on the open screen; the heading fills in once the page scrolls')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
