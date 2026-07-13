const STORAGE_KEY='padelMatchmakerVersion5';
let squad=[];
let tonightIds=[];
let tournamentId=null;
let currentRound=0;
let displayedRound=0;
let rounds=[];
let participantTarget=20;
let selectedProfileId=null;
let profileReturnView='squadView';

function uid(prefix='id'){
  return prefix+'-'+Date.now()+'-'+Math.random().toString(36).slice(2,10);
}

function createPlayer(name){
  return{
    id:uid('player'),
    name,
    ratingPoints:500,
    games:0,
    wins:0,
    losses:0,
    matchPointsFor:0,
    matchPointsAgainst:0,
    results:[],
    createdAt:new Date().toISOString()
  };
}

function init(){
  loadState();
  migratePlayers();
  cleanInvalidReferences();
  updateUI();
}

function migratePlayers(){
  squad.forEach(p=>{
    if(typeof p.ratingPoints!=='number')p.ratingPoints=typeof p.points==='number'?p.points:500;
    if(typeof p.games!=='number')p.games=0;
    if(typeof p.wins!=='number')p.wins=0;
    if(typeof p.losses!=='number')p.losses=0;
    if(typeof p.matchPointsFor!=='number')p.matchPointsFor=0;
    if(typeof p.matchPointsAgainst!=='number')p.matchPointsAgainst=0;
    if(!Array.isArray(p.results))p.results=[];
  });
  if(!Number.isInteger(participantTarget)||participantTarget<4||participantTarget%4!==0){
    participantTarget=20;
  }
  saveState();
}

function cleanInvalidReferences(){
  const ids=new Set(squad.map(p=>p.id));
  tonightIds=tonightIds.filter(id=>ids.has(id));
  rounds.forEach(r=>{
    r.matches=(r.matches||[]).filter(m=>[...m.teamA,...m.teamB].every(id=>ids.has(id)));
  });
  if(selectedProfileId&&!ids.has(selectedProfileId))selectedProfileId=null;
}

function getCourtCount(){return participantTarget/4;}

function addPlayer(){
  const input=document.getElementById('newPlayerName');
  const name=input.value.trim();
  if(!name){alert('Indtast spillerens navn.');return;}
  if(squad.some(p=>p.name.toLowerCase()===name.toLowerCase())){
    alert('Spilleren findes allerede.');
    return;
  }
  const player=createPlayer(name);
  squad.push(player);
  input.value='';
  saveState();
  updateUI();
  openPlayerProfile(player.id,null,'squadView');
}

function deletePlayer(id,event){
  if(event)event.stopPropagation();
  if(currentRound>0){
    alert('En spiller kan ikke slettes, mens en turnering er i gang.');
    return;
  }
  const player=getPlayer(id);
  if(!player)return;
  const historyText=player.games>0?`\n\nSpilleren har ${player.games} gemte kampe. Statistik og historik slettes også.`:'';
  if(!confirm(`Vil du permanent slette ${player.name} fra bruttotruppen?${historyText}`))return;
  squad=squad.filter(p=>p.id!==id);
  tonightIds=tonightIds.filter(playerId=>playerId!==id);
  if(selectedProfileId===id)selectedProfileId=null;
  saveState();
  updateUI();
  showView('squadView');
}

function editPlayerName(){
  const player=getPlayer(selectedProfileId);
  const input=document.getElementById('profileNameInput');
  if(!player||!input)return;
  const newName=input.value.trim();
  if(!newName){alert('Navnet må ikke være tomt.');return;}
  const duplicate=squad.some(p=>p.id!==player.id&&p.name.toLowerCase()===newName.toLowerCase());
  if(duplicate){alert('Der findes allerede en spiller med dette navn.');return;}
  player.name=newName;
  saveState();
  updateUI();
  renderPlayerProfile();
}

function changeParticipantTarget(){
  const input=document.getElementById('participantTarget');
  const value=Number(input.value);
  if(currentRound>0){
    alert('Antallet af spillere kan ikke ændres, mens turneringen er i gang.');
    input.value=participantTarget;
    return;
  }
  if(!Number.isInteger(value)||value<4||value%4!==0){
    alert('Antallet skal være mindst 4 og deleligt med 4, f.eks. 12, 16 eller 20.');
    input.value=participantTarget;
    return;
  }
  participantTarget=value;
  if(tonightIds.length>participantTarget){
    tonightIds=tonightIds.slice(0,participantTarget);
    alert('De senest valgte spillere er fjernet, så deltagerantallet passer.');
  }
  tournamentId=null;
  rounds=[];
  currentRound=0;
  displayedRound=0;
  saveState();
  updateUI();
}

function toggleTonightPlayer(id){
  if(currentRound>0){alert('Turneringen er startet. Deltagerlisten kan ikke ændres.');return;}
  if(tonightIds.includes(id))tonightIds=tonightIds.filter(x=>x!==id);
  else{
    if(tonightIds.length>=participantTarget){alert(`Der kan højst vælges ${participantTarget} spillere.`);return;}
    tonightIds.push(id);
  }
  saveState();
  updateUI();
}

function confirmTonightPlayers(){
  if(tonightIds.length!==participantTarget){alert(`Der skal vælges præcis ${participantTarget} spillere.`);return;}
  tournamentId=uid('tournament');
  currentRound=0;
  displayedRound=0;
  rounds=[];
  saveState();
  updateUI();
  showView('homeView');
}

function getPlayer(id){return squad.find(p=>p.id===id);}
function getTonightPlayers(){return tonightIds.map(getPlayer).filter(Boolean);}
function getTonightResults(p){return tournamentId?p.results.filter(r=>r.tournamentId===tournamentId):[];}
function getTonightStats(p){
  return getTonightResults(p).reduce((s,r)=>{
    s.games++;
    s.matchPointsFor+=r.scoreFor;
    s.matchPointsAgainst+=r.scoreAgainst;
    r.result==='W'?s.wins++:s.losses++;
    return s;
  },{games:0,wins:0,losses:0,matchPointsFor:0,matchPointsAgainst:0});
}

function getLeaderboard(){
  return getTonightPlayers().sort((a,b)=>{
    const A=getTonightStats(a),B=getTonightStats(b);
    if(b.ratingPoints!==a.ratingPoints)return b.ratingPoints-a.ratingPoints;
    if(B.matchPointsFor!==A.matchPointsFor)return B.matchPointsFor-A.matchPointsFor;
    const ad=A.matchPointsFor-A.matchPointsAgainst;
    const bd=B.matchPointsFor-B.matchPointsAgainst;
    if(bd!==ad)return bd-ad;
    if(B.wins!==A.wins)return B.wins-A.wins;
    return tonightIds.indexOf(a.id)-tonightIds.indexOf(b.id);
  });
}

function getCurrentRoundData(){return rounds.find(r=>r.roundNumber===currentRound);}
function getDisplayedRoundData(){return rounds.find(r=>r.roundNumber===displayedRound);}

function generateNextRound(){
  if(tonightIds.length!==participantTarget){alert(`Vælg først præcis ${participantTarget} spillere.`);showView('squadView');return;}
  if(!tournamentId)tournamentId=uid('tournament');
  if(currentRound>=4){alert('Alle fire runder er oprettet.');return;}
  const prev=getCurrentRoundData();
  if(prev&&!allMatchesSaved(prev)){
    alert(`Gem alle ${getCourtCount()} resultater først.`);
    displayedRound=currentRound;
    showView('matchesView');
    return;
  }
  const leaderboard=getLeaderboard();
  const nextRound=currentRound+1;
  const matches=[];
  for(let court=0;court<getCourtCount();court++){
    const base=court*4;
    matches.push({
      id:uid('match'),tournamentId,round:nextRound,court:court+1,
      teamA:[leaderboard[base].id,leaderboard[base+2].id],
      teamB:[leaderboard[base+1].id,leaderboard[base+3].id],
      rankA:[base+1,base+3],rankB:[base+2,base+4],
      scoreA:null,scoreB:null,saved:false,applied:false
    });
  }
  rounds.push({roundNumber:nextRound,createdAt:new Date().toISOString(),matches});
  currentRound=nextRound;
  displayedRound=nextRound;
  saveState();
  updateUI();
  showView('matchesView');
}

function saveMatch(id){
  const round=rounds.find(r=>r.matches.some(m=>m.id===id));
  const match=round&&round.matches.find(m=>m.id===id);
  if(!match||match.saved)return;
  const a=document.getElementById('scoreA-'+id).value.trim();
  const b=document.getElementById('scoreB-'+id).value.trim();
  if(a===''||b===''){alert('Indtast point for begge par.');return;}
  const scoreA=Number(a),scoreB=Number(b);
  if(!Number.isInteger(scoreA)||!Number.isInteger(scoreB)||scoreA<0||scoreB<0){alert('Resultatet skal være hele, positive tal eller 0.');return;}
  if(scoreA===scoreB){alert('Der skal være et vinderpar.');return;}
  match.scoreA=scoreA;
  match.scoreB=scoreB;
  match.saved=true;
  applyMatchResult(match);
  saveState();
  updateUI();
  if(allMatchesSaved(round)){
    if(round.roundNumber<4){setTimeout(()=>{if(confirm('Alle resultater er gemt. Opret næste runde?'))generateNextRound();},150);}
    else setTimeout(()=>{alert('Alle fire runder er færdige.');showView('leaderView');},150);
  }
}

function applyMatchResult(match){
  if(match.applied)return;
  applyResultToTeam(match,match.teamA,match.scoreA,match.scoreB,match.scoreA>match.scoreB);
  applyResultToTeam(match,match.teamB,match.scoreB,match.scoreA,match.scoreB>match.scoreA);
  match.applied=true;
}

function applyResultToTeam(match,ids,scoreFor,scoreAgainst,won){
  ids.forEach(id=>{
    const p=getPlayer(id);
    if(!p)return;
    p.ratingPoints+=won?50:-50;
    p.games++;
    won?p.wins++:p.losses++;
    p.matchPointsFor+=scoreFor;
    p.matchPointsAgainst+=scoreAgainst;
    p.results.push({
      id:uid('result'),matchId:match.id,tournamentId:match.tournamentId,
      date:new Date().toISOString(),round:match.round,court:match.court,
      result:won?'W':'L',scoreFor,scoreAgainst,ratingChange:won?50:-50
    });
  });
}

function editMatch(id){
  const round=rounds.find(r=>r.matches.some(m=>m.id===id));
  const match=round&&round.matches.find(m=>m.id===id);
  if(!match||!match.saved)return;
  if(match.round<currentRound){alert('Resultatet er låst, fordi en senere runde er oprettet.');return;}
  if(!confirm('Vil du rette resultatet?'))return;
  rollbackMatchResult(match);
  match.scoreA=null;
  match.scoreB=null;
  match.saved=false;
  match.applied=false;
  saveState();
  updateUI();
}

function rollbackMatchResult(match){
  if(!match.applied)return;
  [...match.teamA,...match.teamB].forEach(id=>{
    const p=getPlayer(id);
    if(!p)return;
    const result=p.results.find(r=>r.matchId===match.id);
    if(!result)return;
    p.ratingPoints-=result.ratingChange;
    p.games=Math.max(0,p.games-1);
    if(result.result==='W')p.wins=Math.max(0,p.wins-1);else p.losses=Math.max(0,p.losses-1);
    p.matchPointsFor=Math.max(0,p.matchPointsFor-result.scoreFor);
    p.matchPointsAgainst=Math.max(0,p.matchPointsAgainst-result.scoreAgainst);
    p.results=p.results.filter(r=>r.matchId!==match.id);
  });
  match.applied=false;
}

function allMatchesSaved(round){return round&&round.matches.length===getCourtCount()&&round.matches.every(m=>m.saved);}

function openPlayerProfile(id,event,returnView){
  if(event)event.stopPropagation();
  selectedProfileId=id;
  profileReturnView=returnView||document.querySelector('section:not(.hidden)')?.id||'squadView';
  showView('profileView');
}

function closePlayerProfile(){
  showView(profileReturnView==='profileView'?'squadView':profileReturnView);
}

function getTournamentGroups(player){
  const groups={};
  player.results.forEach(result=>{
    const key=result.tournamentId||'legacy';
    if(!groups[key])groups[key]={id:key,date:result.date,results:[]};
    groups[key].results.push(result);
    if(new Date(result.date)<new Date(groups[key].date))groups[key].date=result.date;
  });
  return Object.values(groups).sort((a,b)=>new Date(b.date)-new Date(a.date));
}

function buildRatingChart(player){
  const results=[...player.results].sort((a,b)=>new Date(a.date)-new Date(b.date));
  if(!results.length)return '<div class="empty-state">Ingen ratinghistorik endnu.</div>';
  const totalChange=results.reduce((sum,r)=>sum+(Number(r.ratingChange)||0),0);
  let rating=player.ratingPoints-totalChange;
  const values=[rating];
  results.forEach(r=>{rating+=Number(r.ratingChange)||0;values.push(rating);});
  const width=640,height=220,pad=28;
  let min=Math.min(...values),max=Math.max(...values);
  if(min===max){min-=50;max+=50;}
  const points=values.map((value,index)=>{
    const x=pad+(index/(values.length-1||1))*(width-pad*2);
    const y=height-pad-((value-min)/(max-min))*(height-pad*2);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  return `<div class="chart-wrap"><svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Ratingudvikling"><line x1="${pad}" y1="${height-pad}" x2="${width-pad}" y2="${height-pad}" class="chart-axis"/><line x1="${pad}" y1="${pad}" x2="${pad}" y2="${height-pad}" class="chart-axis"/><polyline points="${points}" class="chart-line"/><text x="${pad}" y="18" class="chart-label">${max}</text><text x="${pad}" y="${height-6}" class="chart-label">${min}</text></svg></div>`;
}

function renderPlayerProfile(){
  const box=document.getElementById('playerProfile');
  if(!box)return;
  const player=getPlayer(selectedProfileId);
  if(!player){box.innerHTML='<div class="notice">Spilleren findes ikke længere.</div>';return;}
  const tournaments=getTournamentGroups(player);
  const winRate=player.games?Math.round((player.wins/player.games)*100):0;
  const diff=player.matchPointsFor-player.matchPointsAgainst;
  const recent=[...player.results].sort((a,b)=>new Date(b.date)-new Date(a.date)).slice(0,12);
  box.innerHTML=`
    <div class="profile-header">
      <div>
        <div class="profile-kicker">Spillerprofil</div>
        <h2>${escapeHtml(player.name)}</h2>
        <div class="profile-rating">${player.ratingPoints} ratingpoint</div>
      </div>
    </div>

    <div class="profile-stats">
      <div class="profile-stat"><strong>${player.games}</strong>Kampe</div>
      <div class="profile-stat"><strong>${player.wins}</strong>Sejre</div>
      <div class="profile-stat"><strong>${player.losses}</strong>Nederlag</div>
      <div class="profile-stat"><strong>${winRate}%</strong>Winrate</div>
      <div class="profile-stat"><strong>${player.matchPointsFor}</strong>Point for</div>
      <div class="profile-stat"><strong>${formatSigned(diff)}</strong>Pointdiff.</div>
    </div>

    <div class="profile-section">
      <h3>Ratingudvikling</h3>
      ${buildRatingChart(player)}
    </div>

    <div class="profile-section">
      <h3>Rediger spiller</h3>
      <input id="profileNameInput" value="${escapeHtml(player.name)}" aria-label="Spillernavn">
      <button onclick="editPlayerName()">Gem nyt navn</button>
      <button class="red" onclick="deletePlayer('${player.id}',event)">Slet spiller permanent</button>
    </div>

    <div class="profile-section">
      <h3>Turneringer (${tournaments.length})</h3>
      ${tournaments.length?tournaments.map(group=>renderTournamentGroup(group)).join(''):'<div class="empty-state">Ingen turneringer endnu.</div>'}
    </div>

    <div class="profile-section">
      <h3>Seneste kampe</h3>
      ${recent.length?recent.map(result=>renderProfileResult(result)).join(''):'<div class="empty-state">Ingen kampe endnu.</div>'}
    </div>`;
}

function renderTournamentGroup(group){
  const wins=group.results.filter(r=>r.result==='W').length;
  const losses=group.results.length-wins;
  const forPoints=group.results.reduce((sum,r)=>sum+r.scoreFor,0);
  const against=group.results.reduce((sum,r)=>sum+r.scoreAgainst,0);
  const rating=group.results.reduce((sum,r)=>sum+r.ratingChange,0);
  return `<div class="tournament-card"><div><strong>${formatDate(group.date)}</strong><div class="muted">${group.results.length} kampe · ${wins} sejre · ${losses} nederlag</div></div><div class="tournament-score"><strong>${forPoints}-${against}</strong><span>${formatSigned(rating)} rating</span></div></div>`;
}

function renderProfileResult(result){
  return `<div class="result-row"><div class="result-icon ${result.result==='W'?'win':'loss'}">${result.result==='W'?'V':'T'}</div><div><strong>${result.scoreFor}-${result.scoreAgainst}</strong><div class="muted">${formatDate(result.date)} · Runde ${result.round} · Bane ${result.court}</div></div><div class="result-rating ${result.ratingChange>0?'positive':'negative'}">${formatSigned(result.ratingChange)}</div></div>`;
}

function renderSquad(){
  const list=document.getElementById('squadList');
  const q=(document.getElementById('searchPlayer')?.value||'').trim().toLowerCase();
  list.innerHTML='';
  squad.slice().sort((a,b)=>a.name.localeCompare(b.name,'da',{sensitivity:'base'})).filter(p=>p.name.toLowerCase().includes(q)).forEach(p=>{
    const selected=tonightIds.includes(p.id);
    const diff=p.matchPointsFor-p.matchPointsAgainst;
    const el=document.createElement('div');
    el.className='player-card'+(selected?' selected':'');
    el.onclick=()=>toggleTonightPlayer(p.id);
    el.innerHTML=`
      <div class="check">${selected?'✓':''}</div>
      <div>
        <div class="name">${escapeHtml(p.name)}</div>
        <div class="muted">${p.games} kampe · ${p.wins} sejre · ${p.losses} nederlag</div>
        <div class="score-line">Samlet kampscore: ${p.matchPointsFor}-${p.matchPointsAgainst} · diff ${formatSigned(diff)}</div>
      </div>
      <div class="player-actions">
        <div class="points">${p.ratingPoints}</div>
        <button class="profile-player" aria-label="Se profil for ${escapeHtml(p.name)}" onclick="openPlayerProfile('${p.id}',event,'squadView')">Profil</button>
        <button class="delete-player" aria-label="Slet ${escapeHtml(p.name)}" onclick="deletePlayer('${p.id}',event)">🗑️</button>
      </div>`;
    list.appendChild(el);
  });
  document.getElementById('selectedCount').textContent=`Valgt: ${tonightIds.length} / ${participantTarget}`;
}

function renderMatches(){
  const box=document.getElementById('matches');
  const selector=document.getElementById('roundSelector');
  box.innerHTML='';selector.innerHTML='';
  document.getElementById('matchTitle').textContent=currentRound===0?'Kampe':'Kampe · runde '+displayedRound;
  if(!rounds.length){box.innerHTML='<div class="panel"><p class="sub">Der er endnu ikke oprettet nogen kampe.</p></div>';renderMatchStatus(null);return;}
  rounds.forEach(r=>{
    const button=document.createElement('button');
    button.textContent='Runde '+r.roundNumber;
    button.className=r.roundNumber===displayedRound?'':'inactive';
    button.onclick=()=>{displayedRound=r.roundNumber;saveState();renderMatches();};
    selector.appendChild(button);
  });
  let round=getDisplayedRoundData();
  if(!round){displayedRound=currentRound;round=getCurrentRoundData();}
  renderMatchStatus(round);
  round.matches.forEach(match=>{
    const a1=getPlayer(match.teamA[0]),a2=getPlayer(match.teamA[1]);
    const b1=getPlayer(match.teamB[0]),b2=getPlayer(match.teamB[1]);
    if(!a1||!a2||!b1||!b2)return;
    const aWins=match.saved&&match.scoreA>match.scoreB;
    const bWins=match.saved&&match.scoreB>match.scoreA;
    const canEdit=match.saved&&match.round===currentRound;
    const card=document.createElement('article');
    card.className='court-card';
    card.innerHTML=`<div class="court-header"><div class="court-title">Bane ${match.court}</div><div class="court-state ${match.saved?'saved':''}">${match.saved?'✓ Gemt':'Mangler resultat'}</div></div><div class="team ${aWins?'winner':''}">${renderTeamPlayer(a1,match.rankA[0])}${renderTeamPlayer(a2,match.rankA[1])}<div class="rank-info">Par: nr. ${match.rankA[0]} + ${match.rankA[1]}</div></div><div class="vs">MOD</div><div class="team ${bWins?'winner':''}">${renderTeamPlayer(b1,match.rankB[0])}${renderTeamPlayer(b2,match.rankB[1])}<div class="rank-info">Par: nr. ${match.rankB[0]} + ${match.rankB[1]}</div></div>${match.saved?`<div class="saved-result">Resultat: ${match.scoreA}-${match.scoreB}</div>${canEdit?`<button class="secondary" onclick="editMatch('${match.id}')">Ret resultat</button>`:'<div class="muted">Resultatet er låst.</div>'}`:`<div class="score-grid"><div class="score-field"><label>Point til ${escapeHtml(a1.name)} + ${escapeHtml(a2.name)}</label><input id="scoreA-${match.id}" type="number" min="0" step="1" inputmode="numeric" placeholder="0"></div><div class="score-field"><label>Point til ${escapeHtml(b1.name)} + ${escapeHtml(b2.name)}</label><input id="scoreB-${match.id}" type="number" min="0" step="1" inputmode="numeric" placeholder="0"></div></div><button onclick="saveMatch('${match.id}')">Gem resultat for bane ${match.court}</button>`}`;
    box.appendChild(card);
  });
}

function renderTeamPlayer(p,rank){
  const s=getTonightStats(p);
  return `<div class="team-player"><div><strong>${escapeHtml(p.name)}</strong><span class="muted"> · nr. ${rank}</span></div><div class="team-player-score">${p.ratingPoints} point · ${s.matchPointsFor}-${s.matchPointsAgainst}</div></div>`;
}

function renderLeaderboard(){
  const box=document.getElementById('leaderboard');box.innerHTML='';
  if(tonightIds.length!==participantTarget){box.innerHTML=`<div class="notice">Vælg først aftenens ${participantTarget} spillere.</div>`;return;}
  getLeaderboard().forEach((p,i)=>{
    const s=getTonightStats(p);
    const medal=i===0?'🥇':i===1?'🥈':i===2?'🥉':i+1;
    const el=document.createElement('div');
    el.className='leader-card clickable';
    el.onclick=()=>openPlayerProfile(p.id,null,'leaderView');
    el.innerHTML=`<div class="place">${medal}</div><div><div class="name">${escapeHtml(p.name)}</div><div class="muted">I aften: ${s.games} kampe · ${s.wins} sejre · ${s.losses} nederlag</div><div class="score-line">Kampscore i aften: ${s.matchPointsFor}-${s.matchPointsAgainst}</div><div class="muted">Samlet: ${p.games} kampe · ${p.wins} sejre · ${p.losses} nederlag</div></div><div class="points">${p.ratingPoints}</div>`;
    box.appendChild(el);
  });
}

function renderStatus(){
  const courts=getCourtCount();
  document.getElementById('statSquad').textContent=squad.length;
  document.getElementById('statTonight').textContent=tonightIds.length+'/'+participantTarget;
  document.getElementById('statRound').textContent=currentRound+'/4';
  const round=getCurrentRoundData();
  const saved=round?round.matches.filter(m=>m.saved).length:0;
  document.getElementById('statResults').textContent=saved+'/'+courts;
  document.getElementById('participantTarget').value=participantTarget;
  document.getElementById('courtCountText').textContent=`${participantTarget} spillere = ${courts} ${courts===1?'bane':'baner'}`;
  document.querySelectorAll('.status-grid').forEach(el=>el.style.gridTemplateColumns=`repeat(${courts},1fr)`);
  renderHomeStatus(round);
  const notice=document.getElementById('homeNotice');
  if(!squad.length)notice.textContent='Opret først spillere i bruttotruppen.';
  else if(tonightIds.length!==participantTarget)notice.textContent=`Vælg præcis ${participantTarget} spillere til aftenens turnering.`;
  else if(currentRound===0)notice.textContent=`Aftenens ${participantTarget} spillere og ${courts} baner er klar. Lav runde 1.`;
  else if(currentRound===4&&allMatchesSaved(round))notice.textContent='Turneringen er færdig. Se leaderboard.';
  else if(allMatchesSaved(round))notice.textContent='Alle resultater er gemt. Lav næste runde.';
  else notice.textContent='Runde '+currentRound+' er i gang. Registrer resultaterne.';
  document.getElementById('topStatus').textContent=`Bruttotrup: ${squad.length} · Valgt: ${tonightIds.length}/${participantTarget} · Baner: ${courts} · Runde ${currentRound}`;
}

function buildStatusBoxes(round){
  return Array.from({length:getCourtCount()},(_,i)=>i+1).map(court=>{
    const match=round?round.matches.find(m=>m.court===court):null;
    return `<div class="status-box ${!match?'':match.saved?'done':'missing'}">B${court}<br>${!match?'–':match.saved?'✓':'!'}</div>`;
  }).join('');
}
function renderHomeStatus(round){document.getElementById('roundStatus').innerHTML=buildStatusBoxes(round);}
function renderMatchStatus(round){document.getElementById('matchStatus').innerHTML=buildStatusBoxes(round);}

function seedExampleSquad(){
  ['Thomas','Peter','Martin','Søren','Lars','Jens','Kasper','Anders','Mads','Rasmus','Michael','Henrik','Jesper','Niels','Christian','Jonas','Bo','Claus','Mikkel','Frederik','Simon','Mathias','Kim','Jan','Carsten','Emil','Oliver','Nicklas','Brian','Daniel'].forEach(name=>{
    if(!squad.some(p=>p.name.toLowerCase()===name.toLowerCase()))squad.push(createPlayer(name));
  });
  saveState();updateUI();showView('squadView');
}

function resetTonight(){
  if(!confirm('Nulstil aftenens turnering? Resultater fra denne aften trækkes tilbage, mens tidligere statistik bevares.'))return;
  rounds.forEach(r=>r.matches.forEach(m=>{if(m.applied)rollbackMatchResult(m);}));
  tonightIds=[];tournamentId=null;currentRound=0;displayedRound=0;rounds=[];
  saveState();updateUI();showView('squadView');
}

function resetEverything(){
  if(!confirm('Dette sletter hele bruttotruppen, alle scores og resultater. Er du sikker?'))return;
  squad=[];tonightIds=[];tournamentId=null;currentRound=0;displayedRound=0;rounds=[];participantTarget=20;selectedProfileId=null;
  localStorage.removeItem(STORAGE_KEY);updateUI();showView('homeView');
}

function exportData(){
  const json=JSON.stringify({version:6,exportedAt:new Date().toISOString(),squad,tonightIds,tournamentId,currentRound,displayedRound,rounds,participantTarget},null,2);
  if(navigator.clipboard)navigator.clipboard.writeText(json).then(()=>alert('Sikkerhedskopien er kopieret.')).catch(()=>prompt('Kopiér sikkerhedskopien:',json));
  else prompt('Kopiér sikkerhedskopien:',json);
}

function importData(){
  const json=prompt('Indsæt sikkerhedskopien her:');
  if(!json)return;
  try{
    const d=JSON.parse(json);
    if(!Array.isArray(d.squad))throw new Error();
    if(!confirm('Importen erstatter nuværende data. Fortsæt?'))return;
    squad=d.squad||[];tonightIds=d.tonightIds||[];tournamentId=d.tournamentId||null;currentRound=d.currentRound||0;displayedRound=d.displayedRound||currentRound;rounds=d.rounds||[];participantTarget=d.participantTarget||20;
    migratePlayers();cleanInvalidReferences();saveState();updateUI();alert('Data er importeret.');
  }catch{alert('Sikkerhedskopien kunne ikke læses.');}
}

function showView(id){
  ['homeView','squadView','matchesView','leaderView','profileView','adminView'].forEach(view=>{
    document.getElementById(view).classList.add('hidden');
    const tab=document.getElementById('tab-'+view);
    if(tab)tab.classList.remove('active');
  });
  document.getElementById(id).classList.remove('hidden');
  const tab=document.getElementById('tab-'+id);
  if(tab)tab.classList.add('active');
  if(id==='matchesView'&&currentRound>0&&displayedRound===0)displayedRound=currentRound;
  updateUI();
  window.scrollTo({top:0,behavior:'smooth'});
}

function updateUI(){renderSquad();renderMatches();renderLeaderboard();renderStatus();if(selectedProfileId)renderPlayerProfile();}
function saveState(){localStorage.setItem(STORAGE_KEY,JSON.stringify({squad,tonightIds,tournamentId,currentRound,displayedRound,rounds,participantTarget}));}
function loadState(){
  const saved=localStorage.getItem(STORAGE_KEY);
  if(!saved)return;
  try{
    const d=JSON.parse(saved);
    squad=d.squad||[];tonightIds=d.tonightIds||[];tournamentId=d.tournamentId||null;currentRound=d.currentRound||0;displayedRound=d.displayedRound||currentRound;rounds=d.rounds||[];participantTarget=d.participantTarget||20;
  }catch{}
}
function formatSigned(n){return n>0?'+'+n:String(n);}
function formatDate(value){
  try{return new Intl.DateTimeFormat('da-DK',{day:'2-digit',month:'2-digit',year:'numeric'}).format(new Date(value));}
  catch{return value||'-';}
}
function escapeHtml(v){return String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;');}

init();
