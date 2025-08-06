renderFlags: enum_flags u8 {
	// If this is set, rendering will continue (without sleeping!) until it's removed.
	// Use when playing animations.
	renderIndefinitely :: 1;
	
	// Use to ensure we draw at least one more frame.
	// The render thread resets this bit to 0 at the start of each frame automatically.
	renderAtLeastOneMoreFrame :: 1 << 1;
	
	// Use to recompute interface element sizes.
	windowSizeChanged :: 1 << 2;
	
	// Use to tell the render thread to clean up and end itself.
	renderThreadShouldExit :: 1 << 3;
};

renderThreadCriticalSection: RTL_CRITICAL_SECTION;


initRenderThread :: () {
	InitializeCriticalSection(*renderThreadCriticalSection);
	InitializeConditionVariable(*renderThreadWakeConditionVariable);
	
// TODO: Figure out if we really need to do all this. Especially the temporary_storage bit.
	renderThreadContext.allocator = context.allocator;
	renderThreadContext.logger = context.logger;
	renderThreadContext.logger_data = context.logger_data;
	renderThreadContext.temporary_storage = *renderThreadTemporaryStorage;
	
	// The second `null` here can be replaced with a pointer to anything you want, and it will be available as the passed-in parameter in the thread procedure below.
	// For single-window programs, it is simpler to just use globals. Which is how we're accessing mainWindow.
	// For multiple-windows, you could do something like pass an hWnd to its own render thread, all managed in dynamic memory land.
	CreateThread(null, 0, xx enterRenderThread, null, 0, *renderThreadID);
}

renderThreadWakeConditionVariable: CONDITION_VARIABLE;


#scope_file

#import "Windows";

renderThreadID: s32 = 1;
renderThreadTemporaryStorage: Temporary_Storage;
renderThreadContext: #Context;


enterRenderThread :: (_: *void) -> u32 #c_call {
	push_context renderThreadContext {
		// At this time, the main window is not receiving messages yet, so we can presume safe data access without invoking the critical section.
		// But that's not such a big deal perf-wise, so feel free to do it here for peace of mind if you like.
		
		// Here, you can do something like Simp.set_render_target(mainWindow).
		// Or, if doing something more manual, CreateCompatibleDC or GetDC.
		// Simp in particular does not work across multiple threads.
		// Most rendering APIs don't. (Do any?)
		// So here is where you'd init that sort of thing. Not on the main thread.
		// For now, it's just the skeleton. But try it. It will work.
		
		// Render the first frame.
		renderAFrame();
		
		// Now that the main window has contents, show it.
		ShowWindow(mainWindow, SW_SHOW);
		
		// Activate the real window proc.
		mainWindowActivateWindowProc();
		
		// We're now officially rendering and responsive to user input. The program is fully live.
		
		while true {
			// We live in this critical section by default to prevent data races.
			// You can enter/leave this in any thread to modify data that also gets touched by the render thread.
			// For example, player position in a game or inputted chars in a text editor.
			// You can also use Jai's Mutex type for this (modules/Thread). Under the hood on Windows, that uses these critical sections.
			// I just don't personally need all the extra stuff the Jai version does. But, Mutex is cross-platform. That's something.
			EnterCriticalSection(*renderThreadCriticalSection);
			
			// Exit the loop if we're terminating.
			if renderFlags & .renderThreadShouldExit break;
			
			// If another thread wants us to keep rendering, we'll keep rendering.
			if !(renderFlags & (.renderAtLeastOneMoreFrame | .renderIndefinitely)) {
				// If we're here, we don't need to render anything.
				// Put the thread to sleep and wait for a signal to resume rendering.
				SleepConditionVariableCS(*renderThreadWakeConditionVariable, *renderThreadCriticalSection, WIN_TIMEOUT_INFINITE);
			}
			
			// Clear this flag since we're about to render.
			renderFlags &= ~.renderAtLeastOneMoreFrame;
			renderAFrame();
			LeaveCriticalSection(*renderThreadCriticalSection);
			// Here is where other threads have a chance to modify data.
		}
	
		// Clean up if needed.
		LeaveCriticalSection(*renderThreadCriticalSection);
		print("\nThe render thread is exiting.\n");
		
		#import "Debug";
		breakpoint();
	}
	
	return 0;
}

// Assumes we are in the critical section.
renderAFrame :: () {
	// Check if we need to resize interface elements.
	if renderFlags & .windowSizeChanged {
		renderFlags -= .windowSizeChanged;
		// TODO: Resize interface elements.
		
		// TEMP: Just demonstrating that it works.
		print("\nNew Window Size: w=%, h=%\n", mainWindowW, mainWindowH);
	}
	
	// You would render a frame here.
	// Something like:
	// hdc := GetDC(mainWindow);
	// // render
	// ReleaseDC(mainWindow, hdc);
	
	// TEMP: Show we're "rendering" something.
	print(".");
}