
F3X_Sync_Client.lua
package.json
server.js
f3x-sync
/
F3X_Sync_Client.lua
in
main

Edit

Preview
Indent mode

Spaces
Indent size

4
Line wrap mode

No wrap
Editing F3X_Sync_Client.lua file contents
380
381
382
383
384
385
386
387
388
389
390
391
392
393
394
395
396
397
398
399
400
401
402
403
404
405
406
407
408
409
410
411
412
413
414
415
416
417
418
419
420
421
422
423
424
425
426
427
428
429
430
431
432
    warn("[F3X Sync] F3X load error: " .. tostring(runError))
    return
end

notify("Original F3X loaded; sync connected")

-- Send changes only for registered F3X-created parts.
task.spawn(function()
    while true do
        task.wait(UPDATE_INTERVAL)

        for part, id in pairs(localParts) do
            local exists = false

            pcall(function()
                exists = part:IsDescendantOf(Workspace)
            end)

            if not exists then
                if lastSent[part] ~= "__deleted" then
                    send({
                        type = "delete",
                        id = id
                    })

                    lastSent[part] = "__deleted"
                end
            else
                local snapshotOk, snapshot =
                    pcall(capture, part, id)

                if snapshotOk and snapshot then
                    local encodedOk, encoded = pcall(function()
                        return HttpService:JSONEncode(snapshot)
                    end)

                    if encodedOk and encoded ~= lastSent[part] then
                        send({
                            type = lastSent[part] == "__deleted"
                                and "create" or "update",
                            build = snapshot
                        })

                        lastSent[part] = encoded
                    end
                end
            end
        end
    end
end)

print("[F3X Sync] Room: " .. ROOM)

Use Control + Shift + m to toggle the tab key moving focus. Alternatively, use esc then tab to move to the next interactive element on the page.
