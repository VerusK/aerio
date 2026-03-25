// gmail_actions.js
// Performs actions on emails in Gmail Basic HTML view via DOM manipulation.
// Called from Swift via: webView.callAsyncJavaScript(script, arguments: ["action": ..., "msgIds": ...])

"use strict";

// action and msgIds are injected by callAsyncJavaScript arguments
action = action || "";
msgIds = msgIds || [];

function selectMessage(msgId) {
    var checkboxes = document.querySelectorAll("input[type='checkbox']");
    for (var i = 0; i < checkboxes.length; i++) {
        var val = checkboxes[i].getAttribute("value") || checkboxes[i].getAttribute("name") || "";
        if (val === msgId) {
            checkboxes[i].checked = true;
            return true;
        }
    }
    return false;
}

function clickButton(buttonName) {
    var inputs = document.querySelectorAll("input[type='submit'], button");
    for (var i = 0; i < inputs.length; i++) {
        var val = (inputs[i].getAttribute("value") || inputs[i].textContent || "").toLowerCase();
        if (val.indexOf(buttonName.toLowerCase()) !== -1) {
            inputs[i].click();
            return true;
        }
    }
    return false;
}

function performAction(msgIds, buttonNames, actionLabel) {
    var selected = 0;
    for (var i = 0; i < msgIds.length; i++) {
        if (selectMessage(msgIds[i])) selected++;
    }
    if (selected === 0) return { success: false, error: "No messages found to select" };
    for (var j = 0; j < buttonNames.length; j++) {
        if (clickButton(buttonNames[j])) {
            return { success: true, action: actionLabel, count: selected };
        }
    }
    return { success: false, error: actionLabel + " button not found" };
}

var result;
switch (action) {
    case "archive":
        result = performAction(msgIds, ["archive"], "archive");
        break;
    case "delete":
        result = performAction(msgIds, ["delete"], "delete");
        break;
    case "spam":
        result = performAction(msgIds, ["report spam", "spam"], "spam");
        break;
    case "markAsRead":
        result = performAction(msgIds, ["mark as read", "read"], "markAsRead");
        break;
    case "markAsUnread":
        result = performAction(msgIds, ["mark as unread", "unread"], "markAsUnread");
        break;
    default:
        result = { success: false, error: "Unknown action: " + action };
}

return JSON.stringify(result);
