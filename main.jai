#import "Basic";
#load "window.jai";
#load "render.jai";

main :: () {
	SetProcessDPIAware();
	timeBeginPeriod(1);
	
	// Create/show the window.
	mainWindowMinimumSize := POINT.{ cast(s32) demoQuadLength*3, cast(s32) demoQuadLength*3 };
	mainWindow := createAndShowWindow("A great window. Press space to pause/resume the animation.", w = mainWindowMinimumSize.x, h = mainWindowMinimumSize.y);
	setMinimumSize(mainWindow, mainWindowMinimumSize);
	
	// Start rendering.
	startRenderThread(mainWindow);
	
	// Since we don't have to do any rendering on this thread, this loop becomes quite simple.
	while true {
		// Handle OS messages.
		if handleAllRemainingMessages(mainWindow) break;
		
		// If there are no messages, sleep until there is a new one.
		WaitMessage();
	}
}

// We don't need a console window.
#if OS == .WINDOWS {
	#run {
		WR :: #import "Windows_Resources";
		WR.disable_runtime_console();
	}
}