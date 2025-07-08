# LinkedIn Post Draft

So I saw Jack Dorsey's BitChat making waves in the news - a Bluetooth mesh messaging app that works without internet. The concept instantly caught my attention. No servers, no accounts, just pure peer-to-peer communication. As someone who's spent years in the trenches of cybersecurity, I had to take a look under the hood.

What I found? Well... let's just say the road to decentralized hell is paved with good intentions.

The app auto-connects to ANY device advertising its service UUID. Private keys sitting in UserDefaults like they're on vacation. Buffer overflows that would make the 90s proud. Zero session management. It's like building a bulletproof vest out of Swiss cheese.

Here's the thing - I LOVE what BitChat is trying to do. Truly decentralized communication is the dream. But dreams without security become nightmares real quick.

So we did what we do at Unit 221B - we fixed it. All of it.

✅ Added proper Bluetooth authentication (no more auto-connect party)
✅ Moved keys to iOS Keychain where they belong
✅ Fixed those gnarly buffer overflows
✅ Built real session management with HMACs

We discovered vulnerabilities and immediately created a PR with fixes. Here's our gift to the community:

🔐 Secure fork: https://github.com/lancejames221b/bitchat
📋 Full vulnerability report: https://github.com/lancejames221b/bitchat/blob/main/SECURITY_DISCLOSURE.md
🤝 PR to original repo: https://github.com/jackjackbits/bitchat/pull/77

Look, I get it. When you're innovating at the speed of thought, security can feel like that annoying friend who keeps telling you to wear a seatbelt. But here's the reality - if we're going to build the decentralized future, we need to build it right. 

To Jack and the BitChat team - the vision is solid. Let's make the execution match. The code's all there, ready to merge. Because at the end of the day, we're all on the same team here - trying to give people communication tools that actually respect their privacy AND keep them safe.

Stay paranoid, friends. It's a feature, not a bug.

#cybersecurity #infosec #bluetooth #mobilesecurity #decentralized #jackdorsey #bitchat #opensource #appsecurity #cryptography #privacy #unit221b