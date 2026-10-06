"""Rebuild bundled assets locally; requires Pillow. Assets are already included."""
from pathlib import Path
from PIL import Image, ImageDraw
import math, struct, wave
ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets'
ASSETS.mkdir(parents=True, exist_ok=True)
S = 4
image = Image.new('RGBA', (256*S, 256*S), (0,0,0,0))
draw = ImageDraw.Draw(image)
def scaled(points): return [(int(x*S),int(y*S)) for x,y in points]
def cubic(p0,p1,p2,p3,n=70):
 return [((1-t)**3*p0[0]+3*(1-t)**2*t*p1[0]+3*(1-t)*t*t*p2[0]+t**3*p3[0],
          (1-t)**3*p0[1]+3*(1-t)**2*t*p1[1]+3*(1-t)*t*t*p2[1]+t**3*p3[1]) for t in [i/n for i in range(n+1)]]
draw.rounded_rectangle((12*S,12*S,244*S,244*S),radius=52*S,fill='#1768ad')
eye = cubic((42,120),(83,59),(161,59),(208,120)) + cubic((208,120),(161,179),(83,179),(42,120))
draw.line(scaled(eye),fill='white',width=10*S,joint='curve')
draw.ellipse((96*S,91*S,150*S,145*S),outline='white',width=10*S)
draw.ellipse((147*S,148*S,216*S,217*S),fill='#1768ad',outline='#e0f2ff',width=8*S)
draw.line(scaled([(182,163),(182,184),(196,191)]),fill='#e0f2ff',width=7*S,joint='curve')
image = image.resize((256,256),Image.Resampling.LANCZOS)
image.save(ASSETS/'App.png')
image.save(ASSETS/'App.ico',format='ICO',sizes=[(n,n) for n in [16,20,24,32,40,48,64,128,256]])
(ASSETS/'App.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
<rect x="12" y="12" width="232" height="232" rx="52" fill="#1768ad"/>
<path d="M42 120C83 59 161 59 208 120C161 179 83 179 42 120Z" fill="none" stroke="white" stroke-width="10" stroke-linejoin="round"/>
<circle cx="123" cy="118" r="27" fill="none" stroke="white" stroke-width="10"/>
<circle cx="182" cy="182.5" r="34.5" fill="#1768ad" stroke="#e0f2ff" stroke-width="8"/>
<path d="M182 163V184L196 191" fill="none" stroke="#e0f2ff" stroke-width="7" stroke-linejoin="round"/>
</svg>''')
# Soft synthesized tones with attack/release envelopes; no third-party audio assets.
presets = {
 'Gentle': [(523.25,0),(659.25,.32),(783.99,.64)],
 'Bell': [(880,0),(1320,0),(1760,0)],
 'Chime': [(659.25,0),(880,.3),(1046.5,.6)],
 'Clear': [(880,0),(880,.5)],
 'Soft': [(392,0),(523.25,.45)]}
for name, tones in presets.items():
 rate=44100; frames=[]
 for i in range(int(rate*2.2)):
  t=i/rate; value=0
  for frequency,start in tones:
   u=t-start-.08
   if 0 <= u <= 1.5:
    envelope = min(1,u/.025)*math.exp(-3.2*u)*min(1,(1.5-u)/.1)
    value += envelope*(math.sin(2*math.pi*frequency*u)+.16*math.sin(2*math.pi*frequency*2*u))
  frames.append(value)
 peak=max(abs(v) for v in frames) or 1
 path=ASSETS/f'{name}.wav'; path.parent.mkdir(exist_ok=True)
 with wave.open(str(path),'wb') as f:
  f.setparams((1,2,rate,0,'NONE','not compressed'))
  f.writeframes(b''.join(struct.pack('<h',round(v/peak*20000)) for v in frames))
print('Generated 9-size ICO, PNG, SVG and 5 local PCM alarm sounds.')
