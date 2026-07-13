let leaderboardMode=localStorage.getItem('padelLeaderboardMode')||'tonight';
let deferredInstallPrompt=null;

function getTonightRatingChange(player){
  return getTonightResults(player).reduce((sum,result)=>sum+(Number(result.ratingChange)||0),0);
}

function getOverallPointDiff(player){
  return (player.matchPointsFor||0)-(player.matchPointsAgainst||0);
}

function getOverallWinRate(player){
  return player.games?Math.round((player.wins/player.games)*100):0;
}

function setLeaderboardMode(mode){
  leaderboardMode=mode;
  localStorage.setItem('padelLeaderboardMode',mode);
  renderLeaderboard();
  vibrate(20);
}

function getOverallLeaderboard(){
  return [...squad].sort((a,b)=>{
    if(b.ratingPoints!==a.ratingPoints)return b.ratingPoints-a.ratingPoints;
    const aDiff=getOverallPointDiff(a),bDiff=getOverallPointDiff(b);
    if(bDiff!==aDiff)return bDiff-aDiff;
    if((b.matchPointsFor||0)!==(a.matchPointsFor||0))return (b.matchPointsFor||0)-(a.matchPointsFor||0);
    return a.name.localeCompare(b.name,'da');
  });
}

function renderLeaderboard(){
  const box=document.getElementById('leaderboard');
  if(!box)return;
  box.innerHTML=`<div class="leaderboard-toolbar"><button class="${leaderboardMode==='tonight'?'':'inactive'}" onclick="setLeaderboardMode('tonight')">I aften</button><button class="${leaderboardMode==='overall'?'':'inactive'}" onclick="setLeaderboardMode('overall')">Samlet rangliste</button></div>`;

  const players=leaderboardMode==='overall'?getOverallLeaderboard():getLeaderboard();
  if(leaderboardMode==='tonight'&&tonightIds.length!==participantTarget){
    box.innerHTML+='<div class="notice">Turneringen er ikke klar endnu.</div>';
    return;
  }
  if(!players.length){
    box.innerHTML+='<div class="empty-state">Ingen spillere endnu.</div>';
    return;
  }

  players.forEach((player,index)=>{
    const tonight=getTonightStats(player);
    const ratingChange=getTonightRatingChange(player);
    const wins=leaderboardMode==='overall'?player.wins:tonight.wins;
    const losses=leaderboardMode==='overall'?player.losses:tonight.losses;
    const games=leaderboardMode==='overall'?player.games:tonight.games;
    const pointFor=leaderboardMode==='overall'?player.matchPointsFor:tonight.matchPointsFor;
    const pointAgainst=leaderboardMode==='overall'?player.matchPointsAgainst:tonight.matchPointsAgainst;
    const diff=pointFor-pointAgainst;
    const winrate=games?Math.round(wins/games*100):0;
    const medal=index<3?['🥇','🥈','🥉'][index]:index+1;
    const card=document.createElement('div');
    card.className='leader-card advanced-leader clickable';
    card.onclick=()=>openPlayerProfile(player.id,null,'leaderView');
    card.innerHTML=`
      <div class="place">${medal}</div>
      <div>
        <div class="name">${escapeHtml(player.name)}</div>
        <div class="muted">${games} kampe · ${wins} sejre · ${losses} nederlag</div>
        <div class="leader-metrics">
          <span class="metric-pill">Winrate ${winrate}%</span>
          <span class="metric-pill ${diff>0?'positive':diff<0?'negative':''}">Diff ${formatSigned(diff)}</span>
          <span class="metric-pill">Kampscore ${pointFor}-${pointAgainst}</span>
        </div>
      </div>
      <div>
        <div class="points">${player.ratingPoints}</div>
        ${leaderboardMode==='tonight'?`<div class="rating-change ${ratingChange>0?'positive':ratingChange<0?'negative':''}">${formatSigned(ratingChange)} i aften</div>`:''}
      </div>`;
    box.appendChild(card);
  });
}

function quickAdjust(matchId,team,delta){
  const input=document.getElementById(`score${team}-${matchId}`);
  if(!input)return;
  const value=Math.max(0,(Number(input.value)||0)+delta);
  input.value=value;
  vibrate(12);
}

function focusNextMissingCourt(){
  const round=getCurrentRoundData();
  if(!round)return;
  const missing=round.matches.find(match=>!match.saved);
  if(!missing)return;
  const card=document.getElementById('court-'+missing.id);
  if(card){
    card.scrollIntoView({behavior:'smooth',block:'start'});
    card.classList.remove('flash');
    requestAnimationFrame(()=>card.classList.add('flash'));
    setTimeout(()=>document.getElementById('scoreA-'+missing.id)?.focus(),450);
  }
}

function renderMatches(){
  const box=document.getElementById('matches');
  const selector=document.getElementById('roundSelector');
  if(!box||!selector)return;
  box.innerHTML='';
  selector.innerHTML='';
  document.getElementById('matchTitle').textContent=currentRound?'Kampe · runde '+displayedRound:'Kampe';

  if(!rounds.length){
    box.innerHTML='<div class="panel"><p class="sub">Ingen kampe endnu.</p></div>';
    renderMatchStatus(null);
    return;
  }

  const toolbar=document.createElement('div');
  toolbar.className='match-toolbar';
  toolbar.innerHTML='<button class="secondary" onclick="focusNextMissingCourt()">Næste manglende bane</button><button class="secondary" onclick="showView(\'leaderView\')">Live leaderboard</button>';
  box.appendChild(toolbar);

  rounds.forEach(round=>{
    const button=document.createElement('button');
    button.textContent='Runde '+round.roundNumber;
    button.className=round.roundNumber===displayedRound?'':'inactive';
    button.onclick=()=>{displayedRound=round.roundNumber;saveState();renderMatches();};
    selector.appendChild(button);
  });

  const round=getDisplayedRoundData()||getCurrentRoundData();
  if(!round)return;
  renderMatchStatus(round);

  round.matches.forEach(match=>{
    const a1=getPlayer(match.teamA[0]),a2=getPlayer(match.teamA[1]),b1=getPlayer(match.teamB[0]),b2=getPlayer(match.teamB[1]);
    if(!a1||!a2||!b1||!b2)return;
    const aWins=match.saved&&match.scoreA>match.scoreB;
    const bWins=match.saved&&match.scoreB>match.scoreA;
    const card=document.createElement('article');
    card.id='court-'+match.id;
    card.className='court-card';
    card.innerHTML=`
      <div class="court-header"><div class="court-title">Bane ${match.court}</div><div class="court-state ${match.saved?'saved':''}">${match.saved?'✓ Gemt':'Mangler resultat'}</div></div>
      <div class="team ${aWins?'winner':''}">${renderTeamPlayer(a1,match.rankA[0])}${renderTeamPlayer(a2,match.rankA[1])}</div>
      <div class="vs">MOD</div>
      <div class="team ${bWins?'winner':''}">${renderTeamPlayer(b1,match.rankB[0])}${renderTeamPlayer(b2,match.rankB[1])}</div>
      ${match.saved
        ?`<div class="saved-result">${match.scoreA}-${match.scoreB}</div>${match.round===currentRound?`<button class="secondary" onclick="editMatch('${match.id}')">Ret resultat</button>`:''}`
        :`<div class="score-grid">
            <div class="score-field"><span class="score-team-label">${escapeHtml(a1.name)} + ${escapeHtml(a2.name)}</span><div class="quick-score"><button class="secondary" onclick="quickAdjust('${match.id}','A',-1)">−</button><input id="scoreA-${match.id}" type="number" min="0" inputmode="numeric" value="0"><button onclick="quickAdjust('${match.id}','A',1)">+</button></div></div>
            <div class="score-field"><span class="score-team-label">${escapeHtml(b1.name)} + ${escapeHtml(b2.name)}</span><div class="quick-score"><button class="secondary" onclick="quickAdjust('${match.id}','B',-1)">−</button><input id="scoreB-${match.id}" type="number" min="0" inputmode="numeric" value="0"><button onclick="quickAdjust('${match.id}','B',1)">+</button></div></div>
          </div><button onclick="saveMatch('${match.id}')">Gem bane ${match.court}</button>`}`;
    box.appendChild(card);
  });
}

const originalSaveMatch=saveMatch;
saveMatch=function(id){
  originalSaveMatch(id);
  vibrate(35);
  setTimeout(()=>{
    const round=getCurrentRoundData();
    if(round&&round.matches.some(match=>!match.saved))focusNextMissingCourt();
  },260);
};

const originalShowView=showView;
showView=function(id){
  originalShowView(id);
  document.body.classList.toggle('matches-active',id==='matchesView'&&rounds.length>0);
};

function vibrate(duration){
  if(navigator.vibrate)navigator.vibrate(duration);
}

function updateOnlineState(){
  document.body.classList.toggle('offline',!navigator.onLine);
}

window.addEventListener('online',updateOnlineState);
window.addEventListener('offline',updateOnlineState);
updateOnlineState();

window.addEventListener('beforeinstallprompt',event=>{
  event.preventDefault();
  deferredInstallPrompt=event;
  const panel=document.getElementById('installPanel');
  if(panel)panel.classList.remove('hidden');
});

async function installApp(){
  if(!deferredInstallPrompt){
    alert('På iPhone: Tryk på Del-knappen i Safari og vælg “Føj til hjemmeskærm”.');
    return;
  }
  deferredInstallPrompt.prompt();
  await deferredInstallPrompt.userChoice;
  deferredInstallPrompt=null;
  document.getElementById('installPanel')?.classList.add('hidden');
}

if('serviceWorker' in navigator){
  window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js').catch(()=>{}));
}

let touchStartX=0;
document.addEventListener('touchstart',event=>{touchStartX=event.changedTouches[0].screenX;},{passive:true});
document.addEventListener('touchend',event=>{
  const delta=event.changedTouches[0].screenX-touchStartX;
  if(Math.abs(delta)<90)return;
  const views=['homeView','squadView','matchesView','leaderView','adminView'];
  const current=views.findIndex(id=>!document.getElementById(id)?.classList.contains('hidden'));
  if(current<0)return;
  const next=delta<0?Math.min(views.length-1,current+1):Math.max(0,current-1);
  if(next!==current)showView(views[next]);
},{passive:true});

updateUI();
