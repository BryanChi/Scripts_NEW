NewNoteStartPos={}
Note_start = {}
Note_End={}
Note_start_Sum=0
HowManyNotesSelected=1
track= reaper.GetSelectedTrack( 0, 0 )
Sel_item =  reaper.GetSelectedMediaItem( 0, 0 )
take =  reaper.GetActiveTake( Sel_item )
Sel_note =  reaper.MIDI_EnumSelNotes( take, 0 )

for times=0, 10, 1 do

 _, selected, muted, Note_start[times], Note_End[times], chan, pitch, vel = reaper.MIDI_GetNote( take, Sel_note+times )
   if selected then 
    Note_start_Sum = Note_start_Sum+ Note_start[times]
    HowManyNotesSelected=HowManyNotesSelected+1

   end
   


end

for times=0, 10, 1 do

  _, selected, muted, Note_start[times], Note_End[times], chan, pitch, vel = reaper.MIDI_GetNote( take, Sel_note+times )
  if selected then 

    notelength = Note_End[times] - Note_start[times]

    test = (Note_start[times]+Note_start_Sum)/HowManyNotesSelected

    NewNoteStartPos[times] = (Note_start[times] + test)  /2



    reaper.MIDI_SetNote( take, Sel_note+times, nil, nil, NewNoteStartPos[times], NewNoteStartPos[times]+notelength, nil, nil,nil, false )


  end
end
reaper.MIDI_Sort( take )


