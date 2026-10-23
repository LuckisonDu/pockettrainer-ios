# Classroom lesson plan: "Why can AI quietly go wrong?" (30 minutes)

*Draft written with AI help for a student teacher/helper to adapt. Grades 7–12, no prior AI knowledge needed. Needs: phones (any, old is fine) or laptops with a browser; the web version needs no install: https://luckisondu.github.io/pockettrainer-web/*

## Goal
Students train a small AI themselves, see it get quietly ruined without any error message, then see a simple protection fix it — and say in their own words why that matters.

## Plan
| Time | What happens | Notes for the helper |
|---|---|---|
| 0–5 | **Hook.** Ask: "If a calculator gave a wrong answer and showed no error, how would you know?" Take 2–3 answers. | Don't explain yet. |
| 5–10 | **Train.** Open the web version, project "Photo classifier", press **Run**. Watch the curve go down. | Takes seconds. Point out the accuracy number (about 87%) on photos the model has never seen. |
| 10–18 | **Break it.** Protection lab → protection **off** → "Simulate a system interruption" → Run. Result: about 10%, no error. | Have students predict first: "What will happen?" Then reveal. Say clearly: on web/Android the interruption is a software simulation; on a real iPhone it came from a real GPU event. |
| 18–24 | **Fix it.** Turn protection **on**, repeat. Result: about 87% again, "repaired 1 time". Discuss: what did the app do? (It double-checks each step on the CPU and re-does a step if the two disagree.) | Use the "See it in 30 seconds" card for a one-tap version. |
| 24–30 | **Reflect.** Pairs: "Where else could a result be quietly wrong and nobody notices?" One sentence each on a sticky note. | Examples: a sensor, a spreadsheet, a photo filter. |

## Check for understanding (exit ticket, 1 minute)
1. What was different between the two runs? 2. Why is "no error message" a problem? 3. One place you would want a double-check.

## Safety and privacy
No accounts, no photos of students, no personal data are collected. The app works offline. If students use their own phones, they only open a web page.

## Honest limits to tell students
Small model, small data set; the interruption is simulated in the web/Android versions; one demo is not proof for every phone.
