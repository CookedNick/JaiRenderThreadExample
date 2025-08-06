Yo yo yo. Windows programmers. I have spent a lot of time perfecting this window initialization setup. So I thought I'd share the formula that I like the best.
Basically, it:
1. Creates a window with the default window proc. (Because we don't want effects from early WM_SIZE/WM_PAINT events.) We do not show it yet, as it is just a blank window.
2. Starts a second thread for rendering with a critical section for atomic data access and a condition variable to wake up the render thread (if it's sleeping, which it SHOULD be if nothing is currently changing.).
3. In the second thread, after completing the first frame, we finally display the window and set its window proc to our actual window proc. (This one will respond to WM_PAINT by waking the render thread via condition variable, and WM_SIZE will set a bit when the window's size has changed for resizing your UI elements. You can remove this part if you're ImGui-brained and already recompute those sorts of things each frame.)
4. Now, the render thread will continue rendering if we set a bit for things like animations where you want 60 (or whatever) fps. These animations will be perfectly smooth even during window resizes/moves, since those only block the first thread.
5. If the render thread doesn't need to render (the bits aren't set), it will sleep until woken up by the window proc.

To recap, the great things about this setup are:
- By default, 0% CPU/GPU usage. Until a WM_ message is received. **No sleep calls (faking low CPU usage) necessary.** You do work when there's work.
- A few bits and bobs I like the procedure `mainWindowUpdateMinimumSize`. This sort of utility is nice to have if you want that level of control over how your GUI will look. I would consider this a necessary level of polish for production apps.
- Windows messages no longer block rendering. So just like your web browser, file explorer, and pretty much every other piece of software on Earth (except.. games), yours too will be able to render *while* a user drags/resizes your window. Utter black magic, I know.

Kaveats:
- This does not use Simp, Input, or anything like that. Just the Windows API. (It actually doesn't even render anything, but it has all the pieces for you to do so, even with Simp. I've left comments detailing how to do it.)
- Windows example. This is not cross-platform code. THE REASON FOR THAT is... I mean look at it. It's practically all OS-specific code. Everything from the messages loop to the way threads are handled and managed are unique to the OS you're using. My personal approach is to use OS APIs directly, as designed, with no abstractions on top, and to just handle different platforms independently. If you want to abstract though, you certainly could. And modules/Input/windows.jai could be adapted to incorporate these ideas. That said, for this minimal example, that would not have been a very minimal change to make.
