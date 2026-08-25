// Matchmaking v10.4
// Grundregel: 1+3 mod 2+4.
// Ved individuel pointlighed (samme ratingPoints) må spillere flyttes mellem lige-scorede pladser
// for at undgå at samme makkerpar gentages i senere runder.

function partnerKey(a,b){
  return [a,b].sort().join('|');
}

function getUsedPartnerPairs(){
  const used=new Set();
  rounds.forEach(round=>{
    (round.matches||[]).forEach(match=>{
      if(match.teamA?.length===2)used.add(partnerKey(match.teamA[0],match.teamA[1]));
      if(match.teamB?.length===2)used.add(partnerKey(match.teamB[0],match.teamB[1]));
    });
  });
  return used;
}

function hasBeenPartners(a,b,used){
  return used.has(partnerKey(a.id,b.id));
}

function buildTieGroups(players){
  const groups=[];
  let current=[];
  players.forEach(player=>{
    if(!current.length||current[0].ratingPoints===player.ratingPoints){
      current.push(player);
    }else{
      groups.push(current);
      current=[player];
    }
  });
  if(current.length)groups.push(current);
  return groups;
}

function scoreArrangement(players,used){
  let repeats=0;
  for(let base=0;base<players.length;base+=4){
    const p1=players[base],p2=players[base+1],p3=players[base+2],p4=players[base+3];
    if(!p4)continue;
    if(hasBeenPartners(p1,p3,used))repeats++;
    if(hasBeenPartners(p2,p4,used))repeats++;
  }
  return repeats;
}

function tryImproveTieGroup(arr,start,end,used){
  // Kun spillere med præcis samme rating må bytte plads.
  // Vi bruger lokale byt og vælger kun ændringer, der reducerer gentagne makkere.
  let improved=true;
  let safety=0;
  while(improved&&safety<100){
    improved=false;
    safety++;
    const before=scoreArrangement(arr,used);
    let bestScore=before;
    let bestSwap=null;

    for(let i=start;i<=end;i++){
      for(let j=i+1;j<=end;j++){
        [arr[i],arr[j]]=[arr[j],arr[i]];
        const score=scoreArrangement(arr,used);
        [arr[i],arr[j]]=[arr[j],arr[i]];
        if(score<bestScore){
          bestScore=score;
          bestSwap=[i,j];
          if(score===0)break;
        }
      }
      if(bestScore===0)break;
    }

    if(bestSwap){
      [arr[bestSwap[0]],arr[bestSwap[1]]]=[arr[bestSwap[1]],arr[bestSwap[0]]];
      improved=true;
    }
  }
}

function optimizeLeaderboardForPartners(leaderboard){
  const arranged=[...leaderboard];
  const used=getUsedPartnerPairs();
  if(!used.size)return arranged;

  const groups=buildTieGroups(arranged);
  let offset=0;
  groups.forEach(group=>{
    if(group.length>1){
      const start=offset;
      const end=offset+group.length-1;
      tryImproveTieGroup(arranged,start,end,used);
    }
    offset+=group.length;
  });

  return arranged;
}

// Overskriv den oprindelige generator efter app.js/v89.js er indlæst.
generateNextRound=function(){
  if(tonightIds.length!==participantTarget){
    alert(`Vælg først ${participantTarget} aktive spillere.`);
    showView('squadView');
    return;
  }
  if(!tournamentId)tournamentId=uid('tournament');
  if(currentRound>=totalRounds){
    alert('Alle runder er oprettet.');
    return;
  }

  const previous=getCurrentRoundData();
  if(previous&&!allMatchesSaved(previous)){
    alert(`Gem alle ${getCourtCount()} resultater først.`);
    displayedRound=currentRound;
    showView('matchesView');
    return;
  }

  const originalLeaderboard=getLeaderboard();
  const arrangedLeaderboard=currentRound===0
    ? originalLeaderboard
    : optimizeLeaderboardForPartners(originalLeaderboard);

  const next=currentRound+1;
  const matches=[];

  for(let court=0;court<getCourtCount();court++){
    const base=court*4;
    const p1=arrangedLeaderboard[base];
    const p2=arrangedLeaderboard[base+1];
    const p3=arrangedLeaderboard[base+2];
    const p4=arrangedLeaderboard[base+3];

    matches.push({
      id:uid('match'),
      tournamentId,
      round:next,
      court:court+1,
      teamA:[p1.id,p3.id],
      teamB:[p2.id,p4.id],
      rankA:[base+1,base+3],
      rankB:[base+2,base+4],
      scoreA:null,
      scoreB:null,
      saved:false,
      applied:false
    });
  }

  rounds.push({
    roundNumber:next,
    createdAt:new Date().toISOString(),
    matches
  });

  currentRound=next;
  displayedRound=next;
  saveState();
  updateUI();
  showView('matchesView');
};
