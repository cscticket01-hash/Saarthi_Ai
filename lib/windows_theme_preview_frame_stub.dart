import 'package:flutter/material.dart';
class WindowsThemePreviewFrame extends StatelessWidget {
 const WindowsThemePreviewFrame({super.key,required this.seed,required this.brightness,required this.page,this.navigation=0});
 final Color seed;final Brightness brightness;final String page;final int navigation;
 @override Widget build(BuildContext context)=>const Center(child:Text('Full Windows preview is available in the developer website.'));
}
