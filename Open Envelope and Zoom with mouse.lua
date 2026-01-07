r=reaper

function msg(a)
    r.ShowConsoleMsg(tostring(a))
end

start_time                   = reaper.time_precise()
key_state, KEY               = reaper.JS_VKeys_GetState(start_time - 2), nil


for i = 1, 255 do
    if key_state:byte(i) ~= 0 then
        KEY = i; reaper.JS_VKeys_Intercept(KEY, 1)
    end
end

if not KEY then return end


function Key_held()
    key_state = reaper.JS_VKeys_GetState(start_time - 2)
    return key_state:byte(KEY) == 1
end

function Release()
    reaper.JS_VKeys_Intercept(KEY, -1)
    reaper.JS_Window_SetFocus(PreviouslyFocusedWindow)
end




function loop()  

    if not Key_held() then return end


    --[[     state = reaper.JS_VKeys_GetDown( 0.1 ) 

    keyState = reaper.JS_VKeys_GetState(0.5):sub(VKLow, VKHi)
    ]]


    
reaper.defer(loop)

end


reaper.defer(loop)
reaper.atexit(Release)
