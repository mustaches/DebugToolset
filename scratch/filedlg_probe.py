import tkinter as tk
from tkinter import filedialog
import os, time

root = tk.Tk()
root.withdraw()
print('PID', os.getpid(), flush=True)
print('open dialog...', flush=True)
# 在手术录像目录打开对话框：若缩略图生成链在本进程内解码，HEVC 报错
# 会打到本控制台（与应用内「浏览」按钮同一机制）。
f = filedialog.askopenfilename(initialdir=r'H:\Surgery_video', title='probe')
print('result:', f, flush=True)
time.sleep(1)
