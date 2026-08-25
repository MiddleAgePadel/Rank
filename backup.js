const BACKUP_FORMAT='middle-age-padel-excel-v2';

function buildBackupState(){
  return {
    format:BACKUP_FORMAT,
    exportedAt:new Date().toISOString(),
    appVersion:'10.8',
    state:{squad,tonightIds,reserveIds,tournamentId,currentRound,displayedRound,rounds,participantTarget,totalRounds,tournamentHistory,selectedProfileId,profileReturnView}
  };
}

function excelDate(value){
  if(!value)return '';
  const d=new Date(value);
  return Number.isNaN(d.getTime())?String(value):d.toLocaleString('da-DK');
}

function playerName(id){return getPlayer(id)?.name||id||'';}
function xmlEscape(value){return String(value??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;');}
function xmlCell(value){
  const isNumber=typeof value==='number'&&Number.isFinite(value);
  return `<Cell><Data ss:Type="${isNumber?'Number':'String'}">${xmlEscape(value)}</Data></Cell>`;
}
function xmlRow(values){return `<Row>${values.map(xmlCell).join('')}</Row>`;}

function buildPlayersRows(){
  const headers=['Nr','Navn','Rating','Kampe','Sejre','Nederlag','Winrate %','Kamp-point for','Kamp-point imod','Pointdifference','Oprettet','Spiller_ID'];
  const rows=squad.slice().sort((a,b)=>a.name.localeCompare(b.name,'da')).map((p,index)=>[
    index+1,p.name,p.ratingPoints,p.games,p.wins,p.losses,p.games?Math.round((p.wins/p.games)*100):0,p.matchPointsFor,p.matchPointsAgainst,(p.matchPointsFor||0)-(p.matchPointsAgainst||0),excelDate(p.createdAt),p.id
  ]);
  return {headers,rows};
}

function buildTournamentRows(){
  const headers=['Nr','Dato','Vinder','Spillere','Reserver','Runder','Baner','Turnerings_ID'];
  const rows=tournamentHistory.map((t,index)=>[index+1,excelDate(t.date),t.winner||'',t.players||'',Array.isArray(t.reserves)?t.reserves.join(', '):'',t.roundCount||'',t.courts||'',t.id||'']);
  return {headers,rows};
}

function buildMatchRows(){
  const headers=['Dato','Turnerings_ID','Runde','Bane','Par 1 spiller 1','Par 1 spiller 2','Par 2 spiller 1','Par 2 spiller 2','Par 1 point','Par 2 point','Gemt','Kamp_ID'];
  const rows=[];
  const addMatch=(date,t,m,r)=>rows.push([date,t,m.round||r.roundNumber||'',typeof courtLabel==='function'?courtLabel(m.court):('B'+m.court),playerName(m.teamA?.[0]),playerName(m.teamA?.[1]),playerName(m.teamB?.[0]),playerName(m.teamB?.[1]),m.scoreA??'',m.scoreB??'',m.saved?'Ja':'Nej',m.id||'']);
  tournamentHistory.forEach(t=>(t.rounds||[]).forEach(r=>(r.matches||[]).forEach(m=>addMatch(excelDate(t.date),t.id||m.tournamentId||'',m,r))));
  if(tournamentId&&!tournamentHistory.some(t=>t.id===tournamentId))rounds.forEach(r=>(r.matches||[]).forEach(m=>addMatch('Aktuel turnering',tournamentId,m,r)));
  return {headers,rows};
}

function buildResultRows(){
  const headers=['Spiller','Dato','Turnerings_ID','Runde','Bane','Resultat','Point for','Point imod','Ratingændring','Kamp_ID','Spiller_ID'];
  const rows=[];
  squad.forEach(p=>(p.results||[]).forEach(r=>rows.push([p.name,excelDate(r.date),r.tournamentId||'',r.round||'',typeof courtLabel==='function'?courtLabel(r.court):('B'+r.court),r.result==='W'?'Sejr':'Nederlag',r.scoreFor,r.scoreAgainst,r.ratingChange,r.matchId||'',p.id])));
  return {headers,rows};
}

function worksheetXml(name,data,hidden=false){
  const table=[xmlRow(data.headers),...data.rows.map(xmlRow)].join('');
  return `<Worksheet ss:Name="${xmlEscape(name)}"${hidden?' ss:Hidden="1"':''}><Table>${table}</Table></Worksheet>`;
}

function buildExcelXml(){
  const backupJson=JSON.stringify(buildBackupState());
  const chunkSize=25000;
  const backupRows=[];
  for(let i=0;i<backupJson.length;i+=chunkSize)backupRows.push([(i/chunkSize)+1,backupJson.slice(i,i+chunkSize)]);
  return `<?xml version="1.0" encoding="UTF-8"?><?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
${worksheetXml('Spillere',buildPlayersRows())}
${worksheetXml('Turneringer',buildTournamentRows())}
${worksheetXml('Kampe',buildMatchRows())}
${worksheetXml('Resultater',buildResultRows())}
${worksheetXml('BACKUP_DATA',{headers:['Del','Data'],rows:backupRows},true)}
</Workbook>`;
}

function backupFilename(){
  const d=new Date();
  const y=d.getFullYear(),m=String(d.getMonth()+1).padStart(2,'0'),day=String(d.getDate()).padStart(2,'0'),hh=String(d.getHours()).padStart(2,'0'),mm=String(d.getMinutes()).padStart(2,'0');
  return `Padel-sikkerhedskopi-${y}-${m}-${day}-${hh}${mm}.xls`;
}

function forceDownload(blob,name){
  const url=URL.createObjectURL(blob);
  const a=document.createElement('a');
  a.href=url;
  a.download=name;
  a.rel='noopener';
  document.body.appendChild(a);
  a.click();
  setTimeout(()=>{a.remove();URL.revokeObjectURL(url);},5000);
}

async function exportData(){
  try{
    const xml=buildExcelXml();
    const blob=new Blob(['\ufeff',xml],{type:'application/vnd.ms-excel;charset=utf-8'});
    const name=backupFilename();
    const file=new File([blob],name,{type:'application/vnd.ms-excel'});

    if(navigator.share&&navigator.canShare&&navigator.canShare({files:[file]})){
      try{
        await navigator.share({files:[file],title:'Padel sikkerhedskopi'});
        return;
      }catch(error){
        if(error?.name==='AbortError')return;
      }
    }

    forceDownload(blob,name);
    setTimeout(()=>alert('Excel-sikkerhedskopien er oprettet. Hvis du bruger iPhone, find filen i Downloads/Arkiver.'),300);
  }catch(error){
    console.error('Backup export fejl',error);
    alert('Sikkerhedskopien kunne ikke oprettes.');
  }
}

function importData(){
  let input=document.getElementById('excelBackupInput');
  if(!input){
    input=document.createElement('input');
    input.id='excelBackupInput';
    input.type='file';
    input.accept='.xls,.xml,application/vnd.ms-excel,text/xml,application/xml';
    input.style.display='none';
    document.body.appendChild(input);
    input.addEventListener('change',handleBackupFile);
  }
  input.value='';
  input.click();
}

function extractBackupJsonFromXml(text){
  const doc=new DOMParser().parseFromString(text,'application/xml');
  if(doc.querySelector('parsererror'))throw new Error('Ugyldig XML');
  const sheets=Array.from(doc.getElementsByTagNameNS('urn:schemas-microsoft-com:office:spreadsheet','Worksheet'));
  const backupSheet=sheets.find(ws=>ws.getAttributeNS('urn:schemas-microsoft-com:office:spreadsheet','Name')==='BACKUP_DATA'||ws.getAttribute('ss:Name')==='BACKUP_DATA');
  if(!backupSheet)throw new Error('BACKUP_DATA mangler');
  const rows=Array.from(backupSheet.getElementsByTagNameNS('urn:schemas-microsoft-com:office:spreadsheet','Row')).slice(1);
  const chunks=rows.map(row=>{
    const cells=Array.from(row.getElementsByTagNameNS('urn:schemas-microsoft-com:office:spreadsheet','Data'));
    return {part:Number(cells[0]?.textContent||0),data:cells[1]?.textContent||''};
  }).sort((a,b)=>a.part-b.part);
  return chunks.map(x=>x.data).join('');
}

function handleBackupFile(event){
  const file=event.target.files?.[0];
  if(!file)return;
  const reader=new FileReader();
  reader.onload=e=>{
    try{
      const text=String(e.target.result||'').replace(/^\uFEFF/,'');
      const backup=JSON.parse(extractBackupJsonFromXml(text));
      if(backup.format!==BACKUP_FORMAT||!backup.state||!Array.isArray(backup.state.squad))throw new Error('Ugyldigt backupformat');
      const state=backup.state;
      if(!confirm(`Importér sikkerhedskopi fra ${excelDate(backup.exportedAt)}?\n\nDen nuværende database i appen erstattes.`))return;
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
      alert(`Sikkerhedskopien er gendannet: ${squad.length} spillere og ${tournamentHistory.length} turneringer.`);
    }catch(error){
      console.error('Backup import fejl',error);
      alert('Filen kunne ikke importeres. Vælg en sikkerhedskopi eksporteret fra denne app.');
    }
  };
  reader.onerror=()=>alert('Filen kunne ikke læses.');
  reader.readAsText(file,'UTF-8');
}
