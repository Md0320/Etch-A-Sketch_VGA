<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The pen is shown as a solid black block when it is down and a hollow black square when it is lifted (the square turns grey where it sits on top of ink, so it stays visible).
After reset the pen is lifted in the middle of the screen. Move it where you want to start, then press START or A.
Pressing two directions on the very same controller update (for example Up and Right together) moves one step diagonally. Opposite directions cancel out.
Reset (`rst_n` low) clears the screen and puts the pen back in the middle, lifted.

## How to test

Start anywhere. The pen starts lifted (Hollow square) in the middle of the screen. Walk it to any spot without leaving a mark, then put it down (press 'A'/solid square) and draw.
'A' key - Start; 'x' key - Erase.


## External hardware

List external hardware used in your project (e.g. PMOD, LED display, etc), if any
