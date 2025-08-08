Hi! This took me a long time to figure out. So here you go.

## The problem we're solving
In Windows (and most operating systems), moving or resizing a window will block the main thread of that program. This is because the OS will enter a "modal loop" in which it absolutely does not want you to have any control..
If you use `CS_HREDRAW | CS_VREDRAW` in your window class's style property, Windows will send you a WM_PAINT message when your contents are no longer valid, and drawing *when you receive this message* is the official way to do smooth resizing in Windows.
That's good! We can render when Windows tells us we need to render! Though one issue remains: **No 60 fps.** Windows will only send us that message when the window's w/h actually change or the window is moved back on-screen by 1+ pixel from being previously off-screen.

## A solution
Here I've solved this by rendering in a background thread. This enables two things:
1. **Full fps during window resizes/moves.**
2. **The main thread can now be solely dedicated to receiving OS messages.** The main benefit of this is the ability to receive key presses and such mid-frame. You could use this to start calculations or work related to user input *for the next frame* while the previous frame is still being drawn.
This is the same solution web browsers use to keep playing a YouTube video while you stretch their windows. Only, web browsers tend to display artifacts during resizes. Check for yourself. Steam is also a program that is rather bad with these artifacts.

## How we avoid artifacts - Part 1
Those browsers (and Steam) fail to smoothly resize because they don't wait for the new frame to actually finish drawing before returning from WM_PAINT.
In other words, Windows is being given the go-ahead to actually resize the window and display it in its new size before it has a frame ready for the new size.
In this example, we've circumvented that problem simply by waiting for the render thread to finish the new frame before returning from WM_PAINT via a condition variable.

## How we avoid artifacts - Part 2
Aaaand because GPUs don't display things the instant you hand them work to do, we fudge the difference by sleeping for 2ms before returning from WM_PAINT. I've tested this part extensively. Without the sleep, you'll be at the mercy of a minor delay between CPU commands to the GPU and the GPU actually doing them. The sleep can make it work at a hardly-noticable cost to resizing responsiveness. I can't really notice it on my 95Hz monitor.
If you have a good GPU, you may be able to get away with 1ms for the sleep. But 2ms was necessary to eliminate artifacts on my computer with an Intel HD 5000 iGPU from 2014. If you want to support computers that old, 2 is good. Otherwise, maybe 1 if you'd rather have the most responsive resizing possible.

**IF YOU USE V-SYNC:** You WILL have artifacting. OR you can sleep in WM_PAINT for like 5-17 ms. 17 should be perfect for 60fps displays. Less for higher refresh rates. Basically you'll need to wait for "up to" the length of a full frame. Typical v-sync delay from user input. I personally hate v-sync. It kills responsiveness. But I'd still use it for playing videos or things like that to eliminate tearing when it matters most. Here we're just discussing everything in relation to responsive window resizing.

## A few extra details
- If we're not animating, we don't render! 0% CPU/GPU in that case. Laptop users love us.
  - When we need to, we can wake the render thread and have it either draw a single frame when something changed or to render continuously for an animation. For example, WM_PAINT wakes it up to draw a single frame.
    - If it was already rendering, not a problem. It will continue. And we can wait in WM_PAINT for the one we requested to be done.
- We're using Simp to render in this example. But you can do this with DirectX/Vulkan/whatever instead and it should work. So long as the library doesn't assume we live on the main thread. If you do end up in that situation, you could do the "Dangerous Threads Crew" (CMuratori) thing and put your WINDOWING logic in a background thread instead.
- We're not using *modules/Input* or *modules/Window_Creation*. This is a **minimal** example and those modules are HUGE. But you could adapt them to do this, but they're not really designed to allow it.
- We're syncing data between threads with our own primitive, `ThreadSafe`. It's just a generic type that wraps your value and provides a critical section for safe access across multiple threads. You'll see its usage throughout the code. I greatly prefer this way of doing things than trying to remember to manually enter/leave critical sections at the appropriate time. Your call.

## License
The license of this repository is the unlicense, so it's effectly public domain. Do whatever!

## Questions?
If you're in the beta Discord for Jai, ping me `@CookedNick`. I'm findable by my name in there. Otherwise, I'm on Twitter. Same handle.
