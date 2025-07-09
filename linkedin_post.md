# LinkedIn Post Draft

Saw Jack Dorsey's BitChat in the news this morning - a Bluetooth mesh messaging app that works without internet. A friend brought it up to me later in the day, so naturally I had to take a look.

Started poking at it with our security tools and AI analysis. Found a bunch of vulnerabilities - auto-connecting to any device, private keys in UserDefaults, buffer overflows, no session management.

This is why I love open source. We can move fast on these things. Combined with AI tools, we quickly put together fixes and submitted a PR with a full security-hardened fork.

🔐 Secure fork: https://github.com/lancejames221b/bitchat
🤝 PR with fixes: https://github.com/jackjackbits/bitchat/pull/77

The concept is brilliant - decentralized messaging without servers. Just needs some security bits flipped from 0 to 1.

#cybersecurity #opensource #jackdorsey #bitchat #appsecurity #decentralized