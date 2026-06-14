This is a proof of concept PowerShell Module to control the Thermal Mode of the 1st Generation Lenovo Legion Go. This was generated through ChatGPT, utilizing trial and error and is a far cry slicker than having to hit hardware buttons and using the left control stick to navigate the Legion Space flyout menu. Like it says in the module, USE THIS AT YOUR OWN RISK as it messes with the handheld TDP.  The biggest draw for me for this module is being able to use Get-LegionThermalMode and Set-LegionThermalMode to change from Quiet, Balanced, Performance and Custom Thermal Mode. 

Be aware that the Custom Thermal changes do take place in the current open session, verified with HWInfo64, but in checking the DAService that Lenovo Space runs will override it at restart/refresh with the slider values which I think are possibly stored in a few small SQLite databases that Space keeps in AppDate\Local\LegionSpace\ludp.

This is written for 5.1 and not PowerShell7.
