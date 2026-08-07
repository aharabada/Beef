using System;
using System.Collections;
using Beefy.widgets;
using Beefy.theme.dark;
using IDE.Debugger;

namespace IDE.ui
{
	class StepIntoSpecificSelector
	{
		class StepIntoSpecificMenuWidget : DarkMenuWidget
		{
			public StepIntoSpecificSelector mSelector;

			public this(Menu menu) : base(menu)
			{
			}

			public override void Update()
			{
				base.Update();

				// Close if the debugger resumed, stopped or re-paused somewhere else
				if ((!gApp.mDebugger.IsPaused()) || (gApp.mDebuggerContinueIdx != mSelector.mDebuggerContinueIdx))
					Close();
			}
		}

		StepIntoSpecificMenuWidget mMenuWidget;
		public int32 mDebuggerContinueIdx;

		public void Show(SourceEditWidgetContent ewc, float x, float y, List<DebugManager.LineCall> calls)
		{
			mDebuggerContinueIdx = gApp.mDebuggerContinueIdx;

			Menu menu = new Menu();
			for (var call in calls)
			{
				String label = scope .();
				call.GetDisplayName(label);
				var item = menu.AddItem(label);
				// StepIntoSpecific steps in unfiltered - the icon just hints that a step filter applies
				if ((call.mIsFiltered) || (call.mIsDefaultFiltered))
					item.mIconImage = DarkTheme.sDarkTheme.GetImage(.StepFilter);
				int callAddr = call.mAddr;
				item.mOnMenuItemSelected.Add(new (menu) =>
					{
						gApp.StepIntoSpecific(callAddr);
					});
			}

			mMenuWidget = new StepIntoSpecificMenuWidget(menu);
			mMenuWidget.mSelector = this;
			mMenuWidget.Init(ewc, x, y);
			mMenuWidget.mWidgetWindow.mOnWindowKeyDown.Add(new => gApp.[Friend]SysKeyDown);
			mMenuWidget.mOnRemovedFromParent.Add(new (widget, prevParent, widgetWindow) => Closed());
			mMenuWidget.SetSelection(0);
		}

		public void Submit()
		{
			mMenuWidget.SubmitSelection();
		}

		void Closed()
		{
			gApp.mStepIntoSpecificSelector = null;
			delete this;
		}
	}
}
