r = reaper 

dofile(reaper.GetResourcePath().."/UserPlugins/ultraschall_api.lua")
u = ultraschall
Tracks={}
MediaTracks = {}
TrkWhiteList = {}
function msg(A)
    r.ShowConsoleMsg(A)
end

time = 0
        
        
function tablefind(tab,el)
    if tab then 
        for index, value in pairs(tab) do
            if value == el then
                return index
            end
        end
    end
end


function getfromStateChunk (Itm_StateChunk, Str)
    start = Itm_StateChunk:find(Str ) 
    End = Itm_StateChunk:find('\n' , start ) 
    return tonumber(Itm_StateChunk:sub(start+string.len(Str),End))
end

TotalTrkNum = r.CountTracks(0)

function loop()
    if time > 10 then 
        Tracks={}
        local pos = r.GetCursorPosition()

        markeridx,  regionidx = r.GetLastMarkerAndCurRegion(0, pos)
        All_trackstring = ultraschall.CreateTrackString_AllTracks()

        --   trackstring = ultraschall.CreateTrackString(integer firstnumber, integer lastnumber, optional integer step)

        -- get region pos
        Pre_Itm_Pos,  elementtype_prev,  number_prev,  Nxt_Reg_Pos,  elementtype_next,  number_next = ultraschall.GetClosestGoToPoints(All_trackstring , -1,  false --[[Item Edge]],  false--[[Marker]] , true--[[Region]] )

        ItmCount = r.CountMediaItems(0)
        for i=0, ItmCount-1, 1 do 
            
            MediaItem =  r.GetMediaItem(0, i)
            Track = r.GetMediaItem_Track(MediaItem )


            TrkNum = tonumber(r.GetMediaTrackInfo_Value(Track, 'IP_TRACKNUMBER'))



            retval, TrkStateChunk = r.GetTrackStateChunk(Track , '', false)

            local rv, Itm_StateChunk = r.GetItemStateChunk(MediaItem , '' , false)
            
            ItmStart = getfromStateChunk (Itm_StateChunk, 'POSITION')
            Len = getfromStateChunk (Itm_StateChunk, 'LENGTH')
            ItmEnd = ItmStart+Len

            if ItmStart > Pre_Itm_Pos then 
                table.insert(Tracks, TrkNum)  
            end
            


            
        end 
        
        for i=1, TotalTrkNum, 1 do  --begins with 1 because 0 is master
            if not tablefind(Tracks, i) then   
                MediaTrack =  reaper.GetTrack(0, i-1)
                reaper.SetMediaTrackInfo_Value(MediaTrack, "I_HEIGHTOVERRIDE", 25)
                msg(i)
            end
        end 
        r.UpdateArrange()
        reaper.TrackList_AdjustWindows(true)

        --get all tracks
        --[[ HowManyTrks= r.CountTracks( 0)
        for i=0, HowManyTrks , 1 do 
            trackstring = u.CreateTrackString(i, i)
            local Pre_Itm_Pos,  elementtype_prev,  number_prev,  Nxt_Itm_Pos,  elementtype_next,  number_next = ultraschall.GetClosestGoToPoints( trackstring, -1,  true --[[Item Edge] ],  false--[[Marker] ] , false--[[Region] ] )
        end  ]]
        time=0
        r.defer(loop)
        
    else time = time +1 
        r.defer(loop)
    end

end
r.defer(loop)
r.UpdateArrange()