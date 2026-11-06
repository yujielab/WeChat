// Moments (views/moments.js, src/hub.js): a dot on the way in while a friend has shared something new; one page
// laid out as a profile (the cover to the top edge with a glass button over it, the photo overlapping its edge,
// the name, the handle, when they joined, the counts, Share profile and Edit profile, tabs with the chosen one
// named); the feed with likes and comments; a new moment with photos from the library; your posts; your pictures
// as a wall of cards; deleting; a friend's page from the chat's details, with Message; a friend sharing something
// while it's open; dark; both screens. Two real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/moments.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-moments')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const OUTER={width:466,height:678},INNER={width:951,height:669}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,vp){const ctx=await browser.newContext({viewport:vp,locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,isMobile:true,hasTouch:true});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
// A picture drawn in the page, as bytes (for the file picker) or uploaded as a moment's photo.
const draw=(p,[w,h],[a,b])=>p.evaluate(async([w,h,a,b])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const g=c.getContext('2d');const gr=g.createLinearGradient(0,0,w,h);gr.addColorStop(0,a);gr.addColorStop(1,b);g.fillStyle=gr;g.fillRect(0,0,w,h);g.fillStyle='rgba(255,255,255,.8)';g.beginPath();g.arc(w*.68,h*.35,Math.min(w,h)*.15,0,7);g.fill();const blob=await new Promise(r=>c.toBlob(r,'image/png'));return[...new Uint8Array(await blob.arrayBuffer())]},[w,h,a,b]).then(x=>Buffer.from(x))
const uploadPhoto=async(p,size,colors)=>{const bytes=[...await draw(p,size,colors)];return p.evaluate(async([bytes,w,h])=>{const r=await fetch(`/api/media/upload?kind=moment&w=${w}&h=${h}`,{method:'POST',headers:{'content-type':'image/png'},body:new Uint8Array(bytes)});return{url:(await r.json()).url,type:'image',w,h}},[bytes,...size])}

const B=await account(`mb_${uniq}`,'Coisini',OUTER)
const A=await account(`ma_${uniq}`,'Tokio',OUTER)
const room=(await api(A,'/api/dm',{username:`mb_${uniq}`})).room.id
await api(B,'/api/messages',{room,type:'text',text:'Did you see my sunrise?'})
const sunrise=(await api(B,'/api/moments',{text:'Sunrise on the ridge this morning ☀️',media:[await uploadPhoto(B,[1600,1000],['#f6a35b','#6a4c93'])]})).moment

// 1. A friend shared something since the last look: a dot on the way in.
await A.reload();await A.waitForSelector('.shell')
await A.waitForFunction(()=>document.querySelector('.list-moments')?.classList.contains('fresh'),null,{timeout:8000})
assert.equal(await A.locator('.list-moments').getAttribute('aria-label'),'Moments, new from friends')
await A.screenshot({path:path.join(OUT,'1-dot.png')})

// 2. The page: laid out as a profile; the friends' feed first; the dot goes once seen.
await A.locator('.list-moments').click();await A.locator('.moments-page .mo-item').first().waitFor();await sleep(600)
const head=await A.evaluate(()=>{const q=s=>document.querySelector('.moments-page '+s);const r=s=>q(s).getBoundingClientRect();return{name:q('.mo-name').textContent,handle:q('.mo-handle').textContent,joined:q('.mo-joined').textContent,counts:q('.mo-counts').textContent,pills:[...document.querySelectorAll('.moments-page .mo-pill')].map(b=>b.textContent),tabs:[...document.querySelectorAll('.moments-page .mo-tab')].map(t=>t.getAttribute('aria-label')),selected:q('.mo-tab[aria-selected="true"]').textContent,coverTop:r('.mo-cover').top-r('.sheet-body').top,faceOverCover:r('.mo-face').top<r('.mo-cover').bottom&&r('.mo-face').bottom>r('.mo-cover').bottom,close:q('.mo-close').getAttribute('aria-label')}})
assert.equal(head.name,'Tokio');assert.equal(head.handle,`@ma_${uniq}`);assert.match(head.joined,/^Joined [A-Z][a-z]+ \d{4}$/)
assert.equal(head.counts,'0 Posts1 Friend');assert.deepEqual(head.pills,['Share profile','Edit profile'])
assert.deepEqual(head.tabs,['Moments','Posts','Media']);assert.equal(head.selected,'Moments','the chosen tab names itself')
assert.ok(head.coverTop<=1,'the cover runs to the top edge');assert.ok(head.faceOverCover,'the photo overlaps the cover');assert.equal(head.close,'Close')
assert.equal(await A.evaluate(()=>document.querySelector('.list-moments').classList.contains('fresh')),false,'seen: the dot goes')
await A.screenshot({path:path.join(OUT,'2-page.png')})

// 3. Their moment: like it (at once, and kept), comment on it.
const item=A.locator(`.mo-item[data-id="${sunrise.id}"]`)
assert.equal(await item.locator('.mo-text').textContent(),'Sunrise on the ridge this morning ☀️')
assert.equal(await item.locator('.mo-media[data-n="1"] img').count(),1)
await item.locator('.mo-like').click();await sleep(400)
assert.equal(await item.locator('.mo-like').getAttribute('aria-pressed'),'true');assert.match(await item.locator('.mo-likes').textContent(),/Tokio/)
await item.locator('.mo-talk').click();await item.locator('.mo-reply input').fill('Gorgeous! Where is this?');await item.locator('.mo-reply input').press('Enter');await sleep(500)
assert.match(await item.locator('.mo-comments').textContent(),/Tokio Gorgeous! Where is this\?/)
const kept=(await A.evaluate(async id=>(await (await fetch('/api/moments/'+id)).json()).moment,sunrise.id))
assert.equal(kept.liked,true);assert.equal(kept.comments.length,1)
await item.scrollIntoViewIfNeeded();await A.screenshot({path:path.join(OUT,'3-liked.png')})

// 4. A new one: words and two photos from the library, shared on Post; it leads the feed.
await A.locator('.mo-compose').click();await A.locator('.mo-composer').waitFor();await sleep(400)
assert.equal(await A.locator('.mo-post').isDisabled(),true,'nothing to share yet')
await A.locator('.mo-composer-body textarea').fill('Weekend roundup: mountains and a sunset')
await A.locator('.mo-composer input[type=file]').setInputFiles([{name:'a.png',mimeType:'image/png',buffer:await draw(A,[1200,900],['#2b5876','#4e4376'])},{name:'b.png',mimeType:'image/png',buffer:await draw(A,[900,1200],['#ee9ca7','#ffdde1'])}])
await A.waitForFunction(()=>document.querySelectorAll('.mo-composer .mo-pick').length===2)
assert.equal(await A.locator('.mo-composer .mo-pick-add').count(),1,'room for more')
await A.screenshot({path:path.join(OUT,'4-composer.png')})
await A.locator('.mo-post').click();await A.locator('.mo-composer').waitFor({state:'detached'});await sleep(500)
const first=A.locator('.moments-page .mo-item').first()
assert.equal(await first.locator('.mo-text').textContent(),'Weekend roundup: mountains and a sunset')
assert.equal(await first.locator('.mo-media[data-n="2"] img').count(),2)
assert.equal(await A.locator('.moments-page .mo-counts').textContent(),'1 Post1 Friend')
// B sees it.
assert.ok((await B.evaluate(async()=>(await (await fetch('/api/moments')).json()).moments.map(m=>m.text))).includes('Weekend roundup: mountains and a sunset'))

// 5. Your posts; your pictures as a wall of cards with how many there are.
await A.locator('.mo-tab[data-tab="posts"]').click();await sleep(700)
assert.deepEqual(await A.locator('.moments-page .mo-item .mo-by').allTextContents(),['Tokio'],'only yours')
await A.locator('.mo-tab[data-tab="media"]').click();await A.locator('.mo-card').first().waitFor();await sleep(500)
assert.equal(await A.locator('.mo-card').count(),1);assert.equal(await A.locator('.mo-card .mo-count').textContent(),'2')
await A.screenshot({path:path.join(OUT,'5-media.png')})
// A card opens its pictures.
await A.locator('.mo-card').click();await A.locator('.viewer').waitFor();await sleep(500);await A.keyboard.press('Escape');await A.locator('.viewer').waitFor({state:'detached'})

// 6. Deleting your own, after asking.
await A.locator('.mo-tab[data-tab="posts"]').click();await sleep(700)
await A.locator('.moments-page .mo-item .mo-dots').first().click();await A.locator('.menu .menu-item:has-text("Delete")').click();await sleep(250)
await A.locator('.menu .menu-item:has-text("Delete")').click();await sleep(600)
assert.equal(await A.locator('.moments-page .mo-item').count(),0);assert.match(await A.locator('.moments-page .mo-empty').textContent(),/Share your first moment/)
assert.equal(await A.locator('.moments-page .mo-counts').textContent(),'0 Posts1 Friend')

// 7. Live: a friend shares something while the feed is open — a pill to see it.
await A.locator('.mo-tab[data-tab="feed"]').click();await sleep(600)
await api(B,'/api/moments',{text:'Clip from the trail'})
await A.locator('.mo-fresh:not([hidden])').waitFor()
await A.locator('.mo-fresh').click();await sleep(800)
assert.equal(await A.locator('.moments-page .mo-item .mo-text').first().textContent(),'Clip from the trail')
await A.locator('.mo-close').click();await A.locator('.moments-page').waitFor({state:'detached'})

// 8. A friend's page, from the chat's details: their posts, Message leads back to the chat.
await A.locator('.row .row-inner').first().click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(500)
await A.locator('.thread:not([hidden]) .thread-title').click();await A.locator('.art-body .cell:has-text("Moments")').waitFor();await sleep(300)
await A.locator('.art-body .cell:has-text("Moments")').click();await A.locator('.moments-page .mo-item').first().waitFor();await sleep(500)
assert.equal(await A.locator('.moments-page .mo-name').textContent(),'Coisini')
assert.deepEqual(await A.locator('.moments-page .mo-pill').allTextContents(),['Share profile','Message'])
assert.deepEqual(await A.locator('.moments-page .mo-tab').evaluateAll(t=>t.map(x=>x.getAttribute('aria-label'))),['Posts','Media'])
assert.equal(await A.locator('.moments-page .mo-compose').isHidden(),true,'no new moment on their page')
await A.screenshot({path:path.join(OUT,'6-friend.png')})
await A.locator('.moments-page .mo-pill:has-text("Message")').click();await A.locator('.moments-page').waitFor({state:'detached'});await sleep(500)
assert.equal(await A.locator('.thread:not([hidden])').count(),1)

// 9. Dark, and the open screen.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'))
await A.setViewportSize(INNER);await sleep(700)
await A.locator('.list-moments').click();await A.locator('.moments-page .mo-item').first().waitFor();await sleep(700)
const box=await A.locator('.moments-page').boundingBox()
assert.ok(Math.abs(box.x+box.width/2-INNER.width/2)<=1,'open, in the middle of the screen '+JSON.stringify(box))
await A.screenshot({path:path.join(OUT,'7-open-dark.png')})
await A.evaluate(()=>{document.querySelector('.moments-page .sheet-body').scrollTop=600});await sleep(500)
assert.equal(await A.evaluate(()=>document.querySelector('.moments-page').classList.contains('mo-scrolled')),true,'the bar fills in once the cover has gone')
await A.screenshot({path:path.join(OUT,'8-open-dark-scrolled.png')})

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: a dot while a friend has shared something new, gone once seen; the page as a profile (cover to the top edge, the photo over its edge, name, handle, joined, counts, Share profile / Edit profile, tabs naming the chosen one); like and comment, at once and kept; a new moment with two photos from the library leads the feed and your friend sees it; your posts; your pictures as a wall of cards; a card opens its pictures; deleting asks first; a friend sharing something while the feed is open shows a pill; a friend\'s page from the chat\'s details with Message back to the chat; dark; centred on the open screen; the bar fills in once the cover has scrolled away')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
