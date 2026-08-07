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

			public bool IsSelectionSubmittable
			{
				get
				{
					return (mSelectIdx >= 0) && (mSelectIdx < mItemWidgets.Count) && (!mItemWidgets[mSelectIdx].mMenuItem.mDisabled);
				}
			}

			/// Returns the first enabled item index at startIdx or continuing in 'dir' (wrapping), or -1
			int FindEnabledIdx(int startIdx, int dir)
			{
				int count = mItemWidgets.Count;
				if (count == 0)
					return -1;
				int idx = startIdx;
				for (int i < count)
				{
					idx = ((idx % count) + count) % count;
					if (!mItemWidgets[idx].mMenuItem.mDisabled)
						return idx;
					idx += dir;
				}
				return -1;
			}

			public void SelectFirstEnabled()
			{
				SetSelection(FindEnabledIdx(0, 1));
			}

			public override void KeyDown(KeyCode keyCode, bool isRepeat)
			{
				// Like MenuWidget.KeyDown, but navigation skips disabled items
				switch (keyCode)
				{
				case .Home:
					SetSelection(FindEnabledIdx(0, 1));
				case .End:
					SetSelection(FindEnabledIdx(mItemWidgets.Count - 1, -1));
				case .Up:
					if (mSelectIdx == -1)
						SelectFirstEnabled();
					else
						SetSelection(FindEnabledIdx(mSelectIdx - 1, -1));
				case .Down:
					if (mSelectIdx == -1)
						SelectFirstEnabled();
					else
						SetSelection(FindEnabledIdx(mSelectIdx + 1, 1));
				case .PageUp:
					if (!mItemWidgets.IsEmpty)
					{
						int32 itemsPerPage = (int32)Math.Ceiling((mParent.mHeight - 8) / mItemWidgets[0].mHeight) - 1;
						SetSelection(FindEnabledIdx(Math.Max(0, mSelectIdx - itemsPerPage), 1));
					}
				case .PageDown:
					if (!mItemWidgets.IsEmpty)
					{
						int32 itemsPerPage = (int32)Math.Ceiling((mParent.mHeight - 8) / mItemWidgets[0].mHeight) - 1;
						SetSelection(FindEnabledIdx(Math.Min(mItemWidgets.Count - 1, Math.Max(0, mSelectIdx) + itemsPerPage), -1));
					}
				case .Return:
					if (IsSelectionSubmittable)
						SubmitSelection();
				default:
					base.KeyDown(keyCode, isRepeat);
				}
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

				if (call.mIsPastAddr)
					item.mDisabled = true;
				else
				{
					int callAddr = call.mAddr;
					item.mOnMenuItemSelected.Add(new (menu) =>
						{
							gApp.StepIntoSpecific(callAddr);
						});
				}

			}

			mMenuWidget = new StepIntoSpecificMenuWidget(menu);
			mMenuWidget.mSelector = this;
			mMenuWidget.Init(ewc, x, y);
			mMenuWidget.mWidgetWindow.mOnWindowKeyDown.Add(new => gApp.[Friend]SysKeyDown);
			mMenuWidget.mOnRemovedFromParent.Add(new (widget, prevParent, widgetWindow) => Closed());
			mMenuWidget.SelectFirstEnabled();
		}

		public void Submit()
		{
			if (!mMenuWidget.IsSelectionSubmittable)
				return;
			mMenuWidget.SubmitSelection();
		}

		void Closed()
		{
			gApp.mStepIntoSpecificSelector = null;
			delete this;
		}
	}
}
