# This fork

This is [pennant-dev/pennant](https://github.com/pennant-dev/pennant) 0.2.0 with two of its changes taken back out:

1. **The Pennant chat.** In 0.2.0 you talk to Pennant in one main chat. It delegates to threads, and the threads can only
   be read. This fork brings back the way threads worked before: you start a thread, write in it whenever you like, and
   start new ones yourself.
2. **The heartbeat.** It's removed completely. Goals run on their own schedules again, as before 0.2.0.

Everything else from 0.2.0 stays: Pennant in your Chrome, working in Mac apps in the background, its own cursor, one
card per decision, helpers wrapping up at their limit, the iPhone's live screen, and the fixes.

## What 0.2.0 changed about threads

These are the changes in upstream commit `61b078e` that make up the Pennant chat, and what each one does.

**Host**
- `Sources/PennantHostKit/Runtime/TaskRuntime+Threads.swift` (new): makes the chat (`ensureMainChat`, called lazily from
  almost everywhere), lets the chat start, message, read and stop threads, builds the work board the chat reads each turn,
  and posts every thread's results, questions and cards back to the chat as `WorkUpdate`s worded by the model
  (`reportFinished`, `reportQuestion`, `reportCard`, `wordUpdate`).
- `Sources/PennantHostKit/Tools/ThreadTools.swift` (new): `start_thread`, `message_thread`, `read_thread`, `stop_thread`.
- `TaskRuntime+Models.swift` (`turnSpecs`): the chat gets the thread tools but not the screen tools, `delegate_task` or
  `await_task`. Every other conversation gets the reverse.
- `TaskRuntime+Context.swift` and `ContextBuilder.swift`: the chat gets the work board and its own rules (`chatRules`,
  `voiceRules`) in place of the house rules. Work that reports to the chat gets `lastMessageRule`.
- `TaskRuntime.swift`: the chat's turns skip the five-task limit. Threads the chat started get a smaller budget
  (`chatThreadBudget`: 30 steps, 45 minutes, 500k tokens) and wrap up at it instead of asking. The chat can't be closed.
- `TaskRuntime+Approvals.swift`, `+Coding.swift`, `+Completion.swift`: each card, question and finished task also
  reports to the chat.
- `TaskRuntime+CardReplacing.swift`, `TaskRuntime+Tools.swift` (Chrome guard): special cases for the chat.
- `HostService.swift`: makes the chat at start, and points iPhone notifications at it.
- `PennantCore`: `Conversation.isMain`, `ContentPart.update`, `WorkUpdate`.

**Apps.** Every change here hangs off `ClientState.mainConversation`, which is nil when the host has no chat.
- `Sources/PennantUI/ConversationView.swift`: in a thread, the message box is replaced by `ThreadFooter` ("Pennant runs
  this thread. To change anything, tell Pennant.") whenever a chat exists. The "new conversation" button goes too.
- `Sources/PennantUI/ThreadListView.swift`: hides the New thread button and regroups the list into "Working on" and "Earlier".
- `Apps/PennantMac/MainWindow.swift`: opens on the chat, pins a big Pennant row above the threads, hides the New thread
  button, and turns an empty pane back into the chat.
- `Apps/PennantMac/ConversationsWindow.swift`: File › New Thread (⌘N) became File › Talk to Pennant.
- `Apps/PennantiOS/RootTabs.swift`: opens on a Pennant tab with threads behind a button, and drops the Inbox tab and the
  new-thread buttons.
- `Sources/PennantUI/PennantChatViews.swift` (new): the chat's own views.
- `Sources/PennantCLI/WorkCommands.swift`: `pennant send` went to the chat by default.

## What this fork does instead

Ripping the chat out would mean changing most of the files above, and every future update from upstream would conflict
with that. Since everything keys off whether a chat exists, this fork switches the chat off at the root instead:

- `HostConfig.pennantChat` (new, **off by default**). Off, `ensureMainChat` refuses to make or find a chat, so nothing is
  ever in the chat or reports to it. That takes care of the work board, the update posts, the tool split, the chat's
  budget and the notifications. Every conversation is an ordinary thread with its normal tools.
- `TaskRuntime.applyChatSetting()` (new), run at start and whenever the setting changes. If you used 0.2.0, your chat
  becomes an ordinary thread called "Pennant chat", with its history. The threads it started come back into the thread
  list, so you can write in them again. Its coding runs stay under it, as a coding run always stays under the thread that
  asked for it.
- With no chat, the apps take the path they already had for hosts from before 0.2.0: the message box in every thread,
  New thread buttons, ⌘N for a new thread, and the Inbox tab on the iPhone. The File menu's label follows the setting.
- `pennant tool` worked through the chat. It now uses Pennant directly when there's no chat.
- Tests: `DirectThreadsTests` covers this fork's behaviour. `PennantChatTests` and the chat's Chrome guard test switch the
  chat on for themselves, so upstream's chat tests still run.

**The heartbeat is deleted**: `Scheduling/Heartbeat.swift`, `HostConfig.heartbeat`, Settings › Pennant › Heartbeat (Mac
and iPhone), `pennant heartbeat`, the heartbeat turn in the chat and its notifications, and `HeartbeatTests`.
`Scheduler.swift` is back to 0.1's (the timer fires goal jobs again), and goal sessions are listed under Schedules and in
the computer panel again. A `heartbeat` key left in your `config.json` is ignored.

## Turning the chat back on

Add `"pennantChat": true` to `~/Library/Application Support/Pennant/config.json` and restart the host. Pennant makes a
new chat. Without the heartbeat, though, it won't take turns on its own.

## Pulling in updates from upstream

```sh
git remote add upstream https://github.com/pennant-dev/pennant.git   # once
git fetch upstream
git merge upstream/main
```

Conflicts are most likely in `TaskRuntime+Threads.swift`, `HostService.swift`, `HostService+Commands.swift`,
`TaskRuntime+Completion.swift`, `Scheduler.swift`, `Config.swift` and the settings screens. Keep this fork's side for the
chat switch and the heartbeat. If upstream builds more on the heartbeat, decide then whether to keep it out. Run
`swift test` afterwards: `DirectThreadsTests` checks the behaviour this fork exists for.

## Building

```sh
brew install xcodegen                                   # once
swift build -c release --product pennant-host           # the host the app embeds
xcodegen generate                                       # makes Pennant.xcodeproj (git ignores it)
open Pennant.xcodeproj                                  # run the PennantMac scheme
```

`Scripts/build-apps.sh` builds both apps without signing. Opening the folder itself in Xcode only shows the Swift package
(the host, the CLI and the libraries). The Mac and iPhone apps live in `project.yml`.
