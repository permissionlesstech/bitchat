#!/usr/bin/env python3
import json
import sys
from pathlib import Path

KEYS = {
    # Payments
    "actions.pay_lightning": ("pay via lightning", "Button label for Lightning payment link"),
    "actions.pay_cashu": ("pay via cashu", "Button label for Cashu token link"),

    # Command help (descriptions)
    "help.command.block": ("block or list blocked peers", "Command description for /block"),
    "help.command.clear": ("clear chat messages", "Command description for /clear"),
    "help.command.hug": ("send someone a warm hug", "Command description for /hug"),
    "help.command.msg": ("send private message", "Command description for /m or /msg"),
    "help.command.slap": ("slap someone with a trout", "Command description for /slap"),
    "help.command.unblock": ("unblock a peer", "Command description for /unblock"),
    "help.command.online": ("see who's online", "Command description for /w"),
    "help.command.fav_add": ("add to favorites", "Command description for /fav"),
    "help.command.fav_remove": ("remove from favorites", "Command description for /unfav"),

    # Accessibility hints
    "accessibility.enter_message_to_send": ("Enter a message to send", "Accessibility hint when input is empty"),
    "accessibility.double_tap_to_send": ("Double tap to send", "Accessibility hint when input has content"),
    "accessibility.remove_favorite": ("Remove from favorites", "Screen reader label to remove a peer from favorites"),

    # Tooltips / help
    "help.verification_qr": ("Verification: show my QR or scan a friend", "Tooltip for verification action"),
    "help.delivered_to_name": ("Delivered to %@", "Tooltip: delivered to a person; %@ is nickname"),
    "help.read_by_name": ("Read by %@", "Tooltip: read by a person; %@ is nickname"),
    "help.failed_reason": ("Failed: %@", "Tooltip: failure with reason; %@ is reason text"),
    "help.delivered_group_members": ("Delivered to %d of %d members", "Tooltip: group delivery status; first %d is reached, second %d is total"),

    # Common labels
    "common.unknown": ("Unknown", "Generic unknown label"),

    # Status labels
    "status.blocked": ("Blocked", "Status indicator for blocked peer"),
    "status.new_messages": ("New messages", "Status indicator for unread messages"),
    "status.blocked_geohash": ("Blocked in geohash", "Status indicator for geohash user blocked"),

    # Verification (macOS placeholder workflow)
    "verify.requested_for": ("verification requested for %@", "Status after requesting verification; %@ is nickname"),
    "verify.could_not_find_peer": ("could not find matching peer", "Error when verification cannot match a peer"),
    "verify.invalid_or_expired_qr": ("invalid or expired qr payload", "Error when pasted QR content is invalid"),

    # App Info — Features
    "appinfo.features.extended_range.title": ("extended range", "Feature title: extended message reach via relays"),
    "appinfo.features.extended_range.desc": ("messages relay through peers, going the distance", "Feature description for extended range"),
    "appinfo.features.favorites.title": ("favorites", "Feature title: favorites"),
    "appinfo.features.favorites.desc": ("get notified when your favorite people join", "Feature description for favorites"),
    "appinfo.features.geohash.title": ("local channels", "Feature title: geohash-based local channels"),
    "appinfo.features.geohash.desc": ("geohash channels to chat with people in nearby regions over decentralized anonymous relays", "Feature description for geohash"),
    "appinfo.features.mentions.title": ("mentions", "Feature title: mentions"),
    "appinfo.features.mentions.desc": ("use @nickname to notify specific people", "Feature description for mentions"),

    # App Info — Privacy
    "appinfo.privacy.no_tracking.title": ("no tracking", "Privacy feature title"),
    "appinfo.privacy.no_tracking.desc": ("no servers, accounts, or data collection", "Privacy feature description"),
    "appinfo.privacy.ephemeral.title": ("ephemeral identity", "Privacy feature title"),
    "appinfo.privacy.ephemeral.desc": ("new peer ID generated regularly", "Privacy feature description"),
    "appinfo.privacy.panic.title": ("panic mode", "Privacy feature title"),
    "appinfo.privacy.panic.desc": ("triple-tap logo to instantly clear all data", "Privacy feature description"),

    # App Info — How To
    "appinfo.howto.set_nickname": ("• set your nickname by tapping it", "How-to instruction bullet"),
    "appinfo.howto.tap_mesh": ("• tap #mesh to change channels", "How-to instruction bullet with #mesh token"),
    "appinfo.howto.open_sidebar": ("• tap people icon for sidebar", "How-to instruction bullet"),
    "appinfo.howto.start_dm": ("• tap a peer's name to start a DM", "How-to instruction bullet"),
    "appinfo.howto.clear_chat": ("• triple-tap chat to clear", "How-to instruction bullet"),
    "appinfo.howto.commands": ("• type / for commands", "How-to instruction bullet with / token"),

    # Fingerprint view messages
    "fp.verified_message": ("you have verified this person's identity.", "Status message shown when fingerprints are verified"),
    "fp.compare_fingerprints_with_name": ("compare these fingerprints with %@ using a secure channel.", "Instruction to compare fingerprints; %@ is the peer's display name"),

    # Notifications — Titles + bodies
    "notifications.mention.title": ("🫵 you were mentioned by %@", "Local notification title for mentions; %@ is sender name"),
    "notifications.private_message.title": ("🔒 private message from %@", "Local notification title for private messages; %@ is sender name"),
    "notifications.favorite_online.title": ("⭐ %@ is online!", "Local notification title when a favorite comes online; %@ is nickname"),
    "notifications.favorite_online.body": ("wanna get in there?", "Local notification body when favorite comes online (casual tone)"),
    "notifications.network_available.title": ("People nearby!", "Local notification title when peers are nearby"),
}

PLURALS = {
    # Nearby people count in notification body
    "notifications.network_available.body": (
        {
            "one": "%d person around",
            "other": "%d people around",
        },
        "Pluralized body: nearby people count; %d is count",
    ),
}

def upsert_keys(path: Path) -> int:
    data = json.loads(path.read_text(encoding='utf-8'))
    strings = data.setdefault('strings', {})
    added = 0
    updated_comment = 0
    for key, (value, comment) in KEYS.items():
        entry = strings.setdefault(key, {})
        locs = entry.setdefault('localizations', {})
        en = locs.setdefault('en', {}).setdefault('stringUnit', {})
        if not en.get('value'):
            en['value'] = value
            en['state'] = 'translated'
            added += 1
        if not entry.get('comment'):
            entry['comment'] = comment
            updated_comment += 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"Seeded {added} keys; set {updated_comment} comments in {path}")
    return 0


def main(argv):
    if len(argv) != 2:
        print('Usage: seed_new_keys.py <path-to-Localizable.xcstrings>')
        return 2
    p = Path(argv[1])
    # Seed simple keys first
    upsert_keys(p)
    # Then seed plurals
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.setdefault('strings', {})
    added = 0
    for key, (forms, comment) in PLURALS.items():
        entry = strings.setdefault(key, {})
        if 'comment' not in entry:
            entry['comment'] = comment
        locs = entry.setdefault('localizations', {})
        en = locs.setdefault('en', {})
        if 'variations' not in en:
            en['variations'] = { 'plural': {} }
            added += 1
        plural = en['variations'].setdefault('plural', {})
        for cat, val in forms.items():
            branch = plural.setdefault(cat, { 'stringUnit': { 'state': 'translated', 'value': val } })
            su = branch.setdefault('stringUnit', {})
            if 'value' not in su:
                su['value'] = val
                su['state'] = 'translated'
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"Seeded {added} plural keys in {p}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

