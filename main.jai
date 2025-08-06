#import "Basic";
#load "window.jai";
#load "render.jai";

main :: () {
	inline initMainWindow();
	mainWindowSetMinimumSize(100, 100);
	inline initRenderThread();
	inline mainWindowReceiveMessages();
	// Do any final cleanup you want here.
}


#if OS == .WINDOWS {
	#run {
		WR :: #import "Windows_Resources";
		WR.disable_runtime_console();
	}
}