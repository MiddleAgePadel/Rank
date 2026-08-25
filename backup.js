const BACKUP_FORMAT='middle-age-padel-xlsx-v1';

function buildBackupState(){
  return {
    format:BACKUP_FORMAT,
    exportedAt:new Date().toISOString(),
    appVersion:'10.7',
    state:{
      squad,
      tonightIds,
      reserveIds,
      tournamentId,
      currentRound,
      displayedRound,
      rounds,
      participantTarget,
      totalRounds,
      tournamentHistory,
      selectedProfileId,
      profileReturnView
    }
  };
}

function excelDate(value){
  if(!value)return '';
  const d=new Date(value);
  return Number.isNaN(d.getTime())?String(value):d.toLocaleString('da-DK');
}

function playerName(id){
  return getPlayer(id)?.name||id||'';
}

function buildPlayersSheet(){
  return squad.slice().sort((a,b)=>a.name.localeCompare(b.name,'da')).map((p,index)=>({
    Nr:index+1,
    Navn:p.name,
    Rating:p.ratingPoints,
    Kampe:p.games,
    Sejre:p.wins,
    Nederlag:p.losses,
    'Winrate %':p.games?Math.round((p.wins/p.games)*100):0,
    'Kamp-point for':p.matchPointsFor,
    'Kamp-point imod':p.matchPointsAgainst,
    Pointdifference:(p.matchPointsFor||0)-(p.matchPointsAgainst||0),
    Oprettet:excelDate(p.createdAt),
    Spiller_ID:p.id
  }));
}

function buildTournamentsSheet(){
  return tournamentHistory.map((t,index)=>({
    Nr:index+1,
    Dato:excelDate(t.date),
    Vinder:t.winner||'',
    Spillere:t.players||'',
    Reserver:Array.isArray(t.reserves)?t.reserves.join(', '):'',
    Runder:t.roundCount||'',
    Baner:t.courts||'',
    Turnerings_ID:t.id||''
  }));
}

function flattenMatches(){
  const rows=[];
  tournamentHistory.forEach(t=>{
    (t.rounds||[]).forEach(r=>{
      (r.matches||[]).forEach(m=>{
        rows.push({
          Dato:excelDate(t.date),
          Turnerings_ID:t.id||m.tournamentId||'',
          Runde:m.round||r.roundNumber||'',
          Bane:typeof courtLabel==='function'?courtLabel(m.court):('B'+m.court),
          'Par 1 spiller 1':playerName(m.teamA?.[0]),
          'Par 1 spiller 2':playerName(m.teamA?.[1]),
          'Par 2 spiller 1':playerName(m.teamB?.[0]),
          'Par 2 spiller 2':playerName(m.teamB?.[1]),
          'Par 1 point':m.scoreA??'',
          'Par 2 point':m.scoreB??'',
          Gemt:m.saved?'Ja':'Nej',
          Kamp_ID:m.id||''
        });
      });
    });
  });

  const currentAlreadyArchived=tournamentId&&tournamentHistory.some(t=>t.id===tournamentId);
  if(tournamentId&&!currentAlreadyArchived){
    rounds.forEach(r=>{
      (r.matches||[]).forEach(m=>{
        rows.push({
          Dato:'Aktuel turnering',
          Turnerings_ID:tournamentId,
          Runde:m.round||r.roundNumber||'',
          Bane:typeof courtLabel==='function'?courtLabel(m.court):('B'+m.court),
          'Par 1 spiller 1':playerName(m.teamA?.[0]),
          'Par 1 spiller 2':playerName(m.teamA?.[1]),
          'Par 2 spiller 1':playerName(m.teamB?.[0]),
          'Par 2 spiller 2':playerName(m.teamB?.[1]),
          'Par 1 point':m.scoreA??'',
          'Par 2 point':m.scoreB??'',
          Gemt:m.saved?'Ja':'Nej',
          Kamp_ID:m.id||''
        });
      });
    });
  }
  return rows;
}

function buildResultsSheet(){
  const rows=[];
  squad.forEach(p=>{
    (p.results||[]).forEach(r=>{
      rows.push({
        Spiller:p.name,
        Dato:excelDate(r.date),
        Turnerings_ID:r.tournamentId||'',
        Runde:r.round||'',
        Bane:typeof courtLabel==='function'?courtLabel(r.court):('B'+r.court),
        Resultat:r.result==='W'?'Sejr':'Nederlag',
        'Point for':r.scoreFor,
        'Point imod':r.scoreAgainst,
        Ratingændring:r.ratingChange,
        Kamp_ID:r.matchId||'',
        Spiller_ID:p.id
      });
    });
  });
  return rows;
}

function sheetFromRows(rows,headers){
  const safeRows=rows.length?rows:[Object.fromEntries(headers.map(h=>[h,'']))];
  const ws=XLSX.utils.json_to_sheet(safeRows,{header:headers});
  if(ws['!ref'])ws['!autofilter']={ref:ws['!ref']};
  return ws;
}

function setColumnWidths(ws,widths){ws['!cols']=widths.map(w=>({wch:w}));}

function createWorkbook(){
  const wb=XLSX.utils.book_new();

  const wsPlayers=sheetFromRows(buildPlayersSheet(),['Nr','Navn','Rating','Kampe','Sejre','Nederlag','Winrate %','Kamp-point for','Kamp-point imod','Pointdifference','Oprettet','Spiller_ID']);
  setColumnWidths(wsPlayers,[5,24,10,9,9,11,11,15,17,15,20,28]);
  XLSX.utils.book_append_sheet(wb,wsPlayers,'Spillere');

  const wsTournaments=sheetFromRows(buildTournamentsSheet(),['Nr','Dato','Vinder','Spillere','Reserver','Runder','Baner','Turnerings_ID']);
  setColumnWidths(wsTournaments,[5,20,24,10,35,8,8,30]);
  XLSX.utils.book_append_sheet(wb,wsTournaments,'Turneringer');

  const wsMatches=sheetFromRows(flattenMatches(),['Dato','Turnerings_ID','Runde','Bane','Par 1 spiller 1','Par 1 spiller 2','Par 2 spiller 1','Par 2 spiller 2','Par 1 point','Par 2 point','Gemt','Kamp_ID']);
  setColumnWidths(wsMatches,[20,30,8,8,22,22,22,22,12,12,8,30]);
  XLSX.utils.book_append_sheet(wb,wsMatches,'Kampe');

  const wsResults=sheetFromRows(buildResultsSheet(),['Spiller','Dato','Turnerings_ID','Runde','Bane','Resultat','Point for','Point imod','Ratingændring','Kamp_ID','Spiller_ID']);
  setColumnWidths(wsResults,[24,20,30,8,8,12,11,12,14,30,28]);
  XLSX.utils.book_append_sheet(wb,wsResults,'Resultater');

  const payload=JSON.stringify(buildBackupState());
  const chunks=[];
  for(let i=0;i<payload.length;i+=30000)chunks.push({Del:(i/30000)+1,Data:payload.slice(i,i+30000)});
  const wsBackup=XLSX.utils.json_to_sheet(chunks,{header:['Del','Data']});
  XLSX.utils.book_append_sheet(wb,wsBackup,'BACKUP_DATA');
  wb.Workbook=wb.Workbook||{};
  wb.Workbook.Sheets=wb.SheetNames.map(name=>({name,Hidden:name==='BACKUP_DATA'?2:0}));
  return wb;
}

function backupFilename(){
  const date=new Date();
  const y=date.getFullYear(),m=String(date.getMonth()+1).padStart(2,'0'),d=String(date.getDate()).padStart(2,'0');
  const hh=String(date.getHours()).padStart(2,'0'),mm=String(date.getMinutes()).padStart(2,'0');
  return `Padel-sikkerhedskopi-${y}-${m}-${d}-${hh}${mm}.xlsx`;
}

async function exportData(){
  if(typeof XLSX==='undefined'){
    alert('Excel-modulet er ikke indlæst. Åbn appen med internetforbindelse og prøv igen.');
    return;
  }

  try{
    const wb=createWorkbook();
    const bytes=XLSX.write(wb,{bookType:'xlsx',type:'array',compression:true});
    const blob=new Blob([bytes],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
    const name=backupFilename();
    const file=new File([blob],name,{type:blob.type});

    // På iPhone/iPad og installeret PWA er delingsarket den mest stabile måde
    // at gemme en genereret fil på. Her kan brugeren vælge "Gem i Arkiver".
    if(navigator.share&&navigator.canShare&&navigator.canShare({files:[file]})){
      await navigator.share({files:[file],title:'Padel sikkerhedskopi',text:'Excel-sikkerhedskopi af Padel Matchmaker'});
      return;
    }

    // Desktop og browsere med almindelig download-understøttelse.
    const url=URL.createObjectURL(blob);
    const a=document.createElement('a');
    a.href=url;
    a.download=name;
    a.style.display='none';
    document.body.appendChild(a);
    a.click();
    setTimeout(()=>{URL.revokeObjectURL(url);a.remove();},3000);
  }catch(error){
    if(error&&error.name==='AbortError')return;
    console.error('Excel export fejl:',error);
    alert('Excel-filen kunne ikke oprettes. Genindlæs appen og prøv igen.');
  }
}

function importData(){
  if(typeof XLSX==='undefined'){
    alert('Excel-modulet er ikke indlæst. Åbn appen med internetforbindelse og prøv igen.');
    return;
  }
  let input=document.getElementById('excelBackupInput');
  if(!input){
    input=document.createElement('input');
    input.id='excelBackupInput';
    input.type='file';
    input.accept='.xlsx,.xls,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    input.style.display='none';
    document.body.appendChild(input);
    input.addEventListener('change',handleBackupFile);
  }
  input.value='';
  input.click();
}

function handleBackupFile(event){
  const file=event.target.files?.[0];
  if(!file)return;
  const reader=new FileReader();
  reader.onload=e=>{
    try{
      const wb=XLSX.read(e.target.result,{type:'array'});
      const ws=wb.Sheets['BACKUP_DATA'];
      if(!ws)throw new Error('BACKUP_DATA mangler');
      const rows=XLSX.utils.sheet_to_json(ws,{defval:''});
      const payload=rows.sort((a,b)=>Number(a.Del)-Number(b.Del)).map(r=>String(r.Data||'')).join('');
      const backup=JSON.parse(payload);
      if(backup.format!==BACKUP_FORMAT||!backup.state||!Array.isArray(backup.state.squad))throw new Error('Ugyldigt backupformat');
      const state=backup.state;
      const exported=backup.exportedAt?excelDate(backup.exportedAt):'ukendt dato';
      if(!confirm(`Importér sikkerhedskopi fra ${exported}?\n\nDen nuværende database i appen erstattes. Gem eventuelt først en ny sikkerhedskopi af de nuværende data.`))return;

      squad=state.squad||[];
      tonightIds=state.tonightIds||[];
      reserveIds=state.reserveIds||[];
      tournamentId=state.tournamentId||null;
      currentRound=state.currentRound||0;
      displayedRound=state.displayedRound||0;
      rounds=state.rounds||[];
      participantTarget=state.participantTarget||20;
      totalRounds=state.totalRounds||4;
      tournamentHistory=state.tournamentHistory||[];
      selectedProfileId=state.selectedProfileId||null;
      profileReturnView=state.profileReturnView||'squadView';
      migratePlayers();cleanInvalidReferences();saveState();updateUI();showView('homeView');
      alert(`Sikkerhedskopien er indlæst. ${squad.length} spillere og ${tournamentHistory.length} gemte turneringer er gendannet.`);
    }catch(error){
      console.error('Excel import fejl:',error);
      alert('Filen kunne ikke importeres. Vælg en Excel-sikkerhedskopi, der er eksporteret fra denne app.');
    }
  };
  reader.onerror=()=>alert('Filen kunne ikke læses.');
  reader.readAsArrayBuffer(file);
}
