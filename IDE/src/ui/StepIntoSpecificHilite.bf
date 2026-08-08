using System;
using System.Collections;
using Beefy.events;
using Beefy.gfx;
using Beefy.theme.dark;
using Beefy.widgets;
using IDE.Debugger;
using Beefy.geom;

namespace IDE.ui
{
	class StepIntoSpecificHilite
	{
		public struct Span
		{
			public int32 mTextIdx; // Absolute index into mData.mText
			public int32 mLength;
			public int32 mEntryIdx; // Execution-order entry; badge text = mEntryIdx + 1
		}

		public struct Entry // One per debugger candidate, in execution order
		{
			public int mCallAddr;
			public bool mIsPast;
			public bool mIsFiltered; // Drives the .StepFilter icon on menu rows
			public String mMenuLabel; // Owned; only set for menu-row entries, else null
			public int32 mSpanIdx; // Index into mSpans, or -1 => lives in the dropdown
			public int32 mMenuRowIdx; // Row in the passive menu, or -1 => inline span
		}

		enum TokenKind
		{
			Identifier, // .Method identifier run
			Operator, // .Method symbol run
			TypeName // Type-classified identifier run (ctor call sites like `new Foo()`)
		}

		struct Token
		{
			public int32 mTextIdx;
			public int32 mLength;
			public StringView mText;
			public TokenKind mKind;
			public bool mClaimed;
		}

		enum MatchKey
		{
			case Unmatchable;
			case Identifier(StringView text);
			case Operator(StringView text);
			case Ctor(StringView typeName);
		}

		public class PassiveMenuWidget : DarkMenuWidget
		{
			public this(Menu menu) : base(menu)
			{
			}

			protected override void HandleKeyDown(KeyDownEvent evt)
			{
				// Keyboard is entirely the editor's job (SourceEditWidgetContent.HandleKey).
				// The base hook would swallow Escape from ALL windows and Close() us directly.
			}

			public override MenuItemWidget CreateMenuItemWidget(Menu menuItem)
			{
				return new PassiveMenuItemWidget(menuItem);
			}

			public override void MouseLeave()
			{
				// Skip DarkMenuWidget.MouseLeave's "mSelectIdx = -1" - selection is coordinator-driven
				mMouseOver = false;
			}
		}

		public class PassiveMenuItemWidget : DarkMenuItem
		{
			public this(Menu menu) : base(menu)
			{
			}

			public override void MouseEnter()
			{
				// Replaces MenuItemWidget.MouseEnter: same hover-select, but WITHOUT the
				// mWidgetWindow.SetForeground() call, which would activate this NoActivate
				// popup and steal editor focus (CheckValid would then cancel the mode)
				mMouseOver = true;
				if ((!mWidgetWindow.mIsMouseMoving) || (mUpdateCnt == 0))
					return;
				if (mMenuItem.mLabel != null)
					mMenuWidget.SetSelection(mIndex);
			}

			public override void MouseLeave()
			{
				// Leaving a row must not clear the mode's selection
				mMouseOver = false;
			}
		}

		public SourceEditWidgetContent mEditWidgetContent;
		public List<Span> mSpans = new .() ~ delete _; // Sorted by mTextIdx (draw order)
		public List<Entry> mEntries = new .() ~
			{
				for (var entry in _)
					delete entry.mMenuLabel;
				delete _;
			};
		public PassiveMenuWidget mMenuWidget; // Null in pure-inline mode and after close
		public int32 mSelIdx; // Entry index (execution order)
		public int32 mDebuggerContinueIdx;
		public int32 mTextVersionId;
		public int32 mCallStackIdx;
		public int32 mUpdateCnt;
		bool mIgnoreMenuSelChange;

		public ~this()
		{
			CloseMenu(); // Runs before the field auto-dtors - entries are still valid here
		}

		static bool IsIdentChar(char8 c)
		{
			return ((c >= 'A') && (c <= 'Z')) || ((c >= 'a') && (c <= 'z')) || ((c >= '0') && (c <= '9')) || (c == '_') || (c == '@');
		}

		static void CollectTokens(SourceEditWidgetContent ewc, int line, String lineText, List<Token> tokens)
		{
			ewc.GetLinePosition(line, var lineStart, var lineEnd);
			for (int i = lineStart; i < lineEnd; i++)
				lineText.Append(ewc.mData.mText[i].mChar);

			int i = lineStart;
			while (i < lineEnd)
			{
				var elemType = (SourceElementType)ewc.mData.mText[i].mDisplayTypeId;
				char8 c = ewc.mData.mText[i].mChar;

				TokenKind kind;
				bool wantIdent;
				if (elemType == .Method)
				{
					wantIdent = IsIdentChar(c);
					kind = wantIdent ? .Identifier : .Operator;
				}
				else if (((elemType == .Type) || (elemType == .Struct) || (elemType == .Interface) || (elemType == .RefType)) && (IsIdentChar(c)))
				{
					wantIdent = true;
					kind = .TypeName;
				}
				else
				{
					i++;
					continue;
				}

				int j = i;
				while ((j < lineEnd) &&
					((SourceElementType)ewc.mData.mText[j].mDisplayTypeId == elemType) &&
					(IsIdentChar(ewc.mData.mText[j].mChar) == wantIdent))
					j++;

				Token token;
				token.mTextIdx = (int32)i;
				token.mLength = (int32)(j - i);
				token.mText = .(lineText, i - lineStart, j - i);
				token.mKind = kind;
				token.mClaimed = false;
				tokens.Add(token);
				i = j;
			}
		}

		static MatchKey DeriveMatchKey(StringView name)
		{
			// Handle the operator segment before dot-splitting - conversion operator names
			// ("operator " + type) can contain dots and spaces in their tail
			for (int i = name.Length - ".operator".Length; i >= 0; i--)
			{
				if (!name.Substring(i).StartsWith(".operator"))
					continue;
				StringView tail = name.Substring(i + ".operator".Length);
				if ((tail.IsEmpty) || (tail[0] == ' '))
					return .Unmatchable; // Conversion operator - the call site is a cast, no .Method token
				if (!IsIdentChar(tail[0]))
					return .Operator(tail);
				break; // A method literally named "operator<ident>..." - treat as a plain method
			}

			StringView comp = name;
			int lastDot = name.LastIndexOf('.');
			if (lastDot != -1)
				comp = name.Substring(lastDot + 1);
			if (comp.EndsWith("<>"))
				comp = comp.Substring(0, comp.Length - 2);

			if ((comp == "this") || (comp == "this$static") || (comp == "this$clear"))
			{
				// Constructor: match the type name token instead (`new Foo()` classifies `Foo` as a type)
				StringView typeComp = default;
				if (lastDot > 0)
				{
					StringView front = name.Substring(0, lastDot);
					int typeDot = front.LastIndexOf('.');
					typeComp = (typeDot != -1) ? front.Substring(typeDot + 1) : front;
					if (typeComp.EndsWith("<>"))
						typeComp = typeComp.Substring(0, typeComp.Length - 2);
				}
				if (typeComp.IsEmpty)
					return .Unmatchable;
				return .Ctor(typeComp);
			}

			if (comp == "~this")
				return .Unmatchable; // Destructor - no call-site token

			if ((comp.StartsWith("get__")) || (comp.StartsWith("set__")))
			{
				StringView rest = comp.Substring("get__".Length);
				if (rest.IsEmpty)
					return .Unmatchable; // Indexer accessor
				return .Identifier(rest);
			}

			if ((comp.IsEmpty) || (comp.StartsWith('<')) || (comp.EndsWith('!')) || (comp.StartsWith('`')))
				return .Unmatchable; // Linkname/mixin/anon leftovers

			return .Identifier(comp);
		}

		static bool TokenMatches(Token token, MatchKey key, int pass)
		{
			switch (key)
			{
			case .Identifier(let text):
				return (pass == 0) && (token.mKind == .Identifier) && (token.mText == text);
			case .Operator(let text):
				// The prefix rule lets a candidate like "operator+" claim a "+=" run
				return (pass == 0) && (token.mKind == .Operator) && ((token.mText == text) || (token.mText.StartsWith(text)));
			case .Ctor(let typeName):
				if (pass == 0) // Explicit `this(...)` chained-ctor call site
					return (token.mKind == .Identifier) && (token.mText == "this");
				return (token.mKind == .TypeName) && (token.mText == typeName);
			default:
				return false;
			}
		}

		public static StepIntoSpecificHilite Create(SourceEditWidgetContent ewc, List<DebugManager.LineCall> calls)
		{
			int line = ewc.CursorLineAndColumn.mLine;

			String lineText = scope .();
			List<Token> tokens = scope .();
			CollectTokens(ewc, line, lineText, tokens);

			List<Span> spans = scope .();
			List<Entry> entries = scope .();
			
			for (var call in calls)
			{
				Entry entry;
				entry.mCallAddr = call.mAddr;
				entry.mIsPast = call.mIsPastAddr;
				entry.mIsFiltered = (call.mIsFiltered) || (call.mIsDefaultFiltered);
				entry.mMenuLabel = null;
				entry.mSpanIdx = -1;
				entry.mMenuRowIdx = -1;

				bool matched = false;
				if (call.mName != null)
				{
					var key = DeriveMatchKey(call.mName);
					if (!(key case .Unmatchable))
					{
						for (int pass < 2)
						{
							// Greedy: execution-order candidates claim the leftmost unclaimed token.
							// Nested same-name calls (`Foo(Foo(x))`) therefore pair the outer token with
							// the inner call - both target the same method, so this is acceptable.
							for (int tokenIdx < tokens.Count)
							{
								var token = ref tokens[tokenIdx];
								if (token.mClaimed)
									continue;
								if (!TokenMatches(token, key, pass))
									continue;

								token.mClaimed = true;
								Span span;
								span.mTextIdx = token.mTextIdx;
								span.mLength = token.mLength;
								span.mEntryIdx = (int32)entries.Count;
								spans.Add(span);
								matched = true;
								break;
							}
							if (matched)
								break;
						}
					}
				}

				entries.Add(entry);
			}

			spans.Sort(scope (lhs, rhs) => lhs.mTextIdx <=> rhs.mTextIdx);
			for (int32 spanIdx < (int32)spans.Count)
				entries[spans[spanIdx].mEntryIdx].mSpanIdx = spanIdx;

			// Unmatched candidates become dropdown rows; build their labels as owned strings
			// while the LineCalls are still alive
			int32 menuRowIdx = 0;
			for (int entryIdx < entries.Count)
			{
				var entry = ref entries[entryIdx];
				if (entry.mSpanIdx != -1)
					continue;
				entry.mMenuRowIdx = menuRowIdx++;
				entry.mMenuLabel = new String();
				entry.mMenuLabel.AppendF("{0}  ", entryIdx + 1);
				calls[entryIdx].GetDisplayName(entry.mMenuLabel);
			}

			var hilite = new StepIntoSpecificHilite();
			hilite.mEditWidgetContent = ewc;
			hilite.mSpans.AddRange(spans);
			hilite.mEntries.AddRange(entries); // Label ownership transfers with the struct copies
			hilite.mDebuggerContinueIdx = gApp.mDebuggerContinueIdx;
			hilite.mTextVersionId = ewc.mData.mCurTextVersionId;
			hilite.mCallStackIdx = gApp.mDebugger.mActiveCallStackIdx;

			// The first non-past entry is the next call to execute - it becomes the initial
			// selection (which may be a dropdown row)
			for (int entryIdx < entries.Count)
			{
				if (!entries[entryIdx].mIsPast)
				{
					hilite.mSelIdx = (int32)entryIdx;
					break;
				}
			}
			return hilite;
		}

		// Called by the edit widget content AFTER the hilite has been assigned to its field, so
		// the menu-closed path (CancelStepIntoSpecificHilite) operates on a live field
		public void ShowMenuIfNeeded(float x, float y)
		{
			bool hasMenuRows = false;
			for (var entry in ref mEntries)
			{
				if (entry.mMenuRowIdx != -1)
				{
					hasMenuRows = true;
					break;
				}
			}
			if (!hasMenuRows)
				return; // Pure inline - numbers only

			Menu menu = new Menu();
			for (int entryIdx < mEntries.Count)
			{
				var entry = ref mEntries[entryIdx];
				if (entry.mMenuRowIdx == -1)
					continue;
				var item = menu.AddItem(entry.mMenuLabel);
				if (entry.mIsFiltered)
					item.mIconImage = DarkTheme.sDarkTheme.GetImage(.StepFilter);
				if (entry.mIsPast)
					item.mDisabled = true; // No listener - un-clickable like the classic selector
				else
				{
					int callAddr = entry.mCallAddr;
					item.mOnMenuItemSelected.Add(new (selMenu) =>
						{
							// DarkMenuItem.Submit Close()s the menu BEFORE firing this, so the
							// mOnMenuClosed handler has already cancelled (deleted) the hilite -
							// only the captured addr may be used here
							gApp.StepIntoSpecific(callAddr);
						});
				}
			}
			menu.mOnMenuClosed.Add(new (closedMenu, itemSelected) =>
				{
					if (mMenuWidget == null)
						return; // We initiated this close from CloseMenu() - no reentrant cancel
					mMenuWidget = null;
					mEditWidgetContent.CancelStepIntoSpecificHilite(); // Deletes 'this'
				});

			mMenuWidget = new PassiveMenuWidget(menu);
			// Keep the default menu flags but never activate the popup, not even on click -
			// the editor keeps focus and all keyboard handling
			mMenuWidget.mWindowFlags |= .NoActivate | .NoMouseActivate;
			mMenuWidget.mOnSelectionChanged.Add(new => OnMenuSelectionChanged);
			mMenuWidget.Init(mEditWidgetContent, x, y);
			SyncMenuSelection();
		}

		void CloseMenu()
		{
			if (mMenuWidget == null)
				return;
			var menuWidget = mMenuWidget;
			mMenuWidget = null; // MUST precede Close(): makes the mOnMenuClosed handler a no-op
			menuWidget.Close(); // Idempotent; the framework deletes the widget with its window
		}

		void OnMenuSelectionChanged(int selIdx)
		{
			if ((mIgnoreMenuSelChange) || (selIdx < 0))
				return;
			for (int entryIdx < mEntries.Count)
			{
				let entry = mEntries[entryIdx];
				if ((entry.mMenuRowIdx == selIdx) && (!entry.mIsPast))
				{
					mSelIdx = (int32)entryIdx;
					break;
				}
			}
		}

		void SyncMenuSelection()
		{
			if (mMenuWidget == null)
				return;
			int32 wantRow = -1;
			if ((mSelIdx >= 0) && (mSelIdx < mEntries.Count))
				wantRow = mEntries[mSelIdx].mMenuRowIdx;
			if (mMenuWidget.mSelectIdx != wantRow)
			{
				mIgnoreMenuSelChange = true;
				mMenuWidget.SetSelection(wantRow);
				mIgnoreMenuSelChange = false;
			}
		}

		public bool CheckValid()
		{
			mUpdateCnt++;
			if ((!gApp.mDebugger.IsPaused()) || (gApp.mDebuggerContinueIdx != mDebuggerContinueIdx))
				return false;
			if (gApp.mDebugger.mActiveCallStackIdx != mCallStackIdx)
				return false;
			if (mEditWidgetContent.mData.mCurTextVersionId != mTextVersionId)
				return false;
			// Grace period: focus may still be in flight right after ShowPCLocation
			if ((mUpdateCnt > 2) && (!mEditWidgetContent.mEditWidget.mHasFocus))
				return false;
			return true;
		}

		public void CycleSelection(int dir)
		{
			int count = mEntries.Count;
			int idx = mSelIdx;
			for (int i < count)
			{
				idx = (((idx + dir) % count) + count) % count;
				if (!mEntries[idx].mIsPast)
				{
					mSelIdx = (int32)idx;
					break;
				}
			}
			SyncMenuSelection();
		}

		public void Submit()
		{
			if ((mSelIdx < 0) || (mSelIdx >= mEntries.Count) || (mEntries[mSelIdx].mIsPast))
				return;
			int addr = mEntries[mSelIdx].mCallAddr;
			// Cancel deletes 'this' (and closes the menu) - no member access after this point
			mEditWidgetContent.CancelStepIntoSpecificHilite();
			gApp.StepIntoSpecific(addr);
		}

		public void DrawHilites(Graphics g)
		{
			var ewc = mEditWidgetContent;
			float height = ewc.mFont.GetHeight();
			float offset = ewc.GetTextOffset();

			for (int spanIdx < mSpans.Count)
			{
				let span = mSpans[spanIdx];
				let entry = mEntries[span.mEntryIdx];
				bool isSelected = (span.mEntryIdx == mSelIdx) && (!entry.mIsPast);

				ewc.GetLineCharAtIdx(span.mTextIdx, let line, let lineChar);
				if (ewc.GetLineHeight(line) <= 0.1f)
					continue; // Collapsed
				ewc.GetTextCoordAtLineChar(line, lineChar, let x, let y);
				ewc.GetTextCoordAtLineChar(line, lineChar + span.mLength, let endX, let endY);
				float width = endX - x;

				if (entry.mIsPast)
				{
					using (g.PushColor(DarkTheme.COLOR_PAST_STEP_INTO_HILITE))
						g.FillRect(x, y + offset, width, height);
				}
				else if (isSelected)
				{
					using (g.PushColor(DarkTheme.COLOR_STEP_INTO_HILITE))
						g.FillRect(x, y + offset, width, height);
					using (g.PushColor(DarkTheme.COLOR_STEP_INTO_OUTLINE))
						g.OutlineRect(x, y + offset, width, height, GS!(1));
				}
				else
				{
					using (g.PushColor(DarkTheme.COLOR_STEP_INTO_HILITE))
						g.FillRect(x, y + offset, width, height);
				}
			}
		}

		public void DrawBadges(Graphics g)
		{
			var ewc = mEditWidgetContent;
			float offset = ewc.GetTextOffset();
			
			float lineHeight = ewc.mFont.GetHeight();
			let badgeFont = DarkTheme.sDarkTheme.mSmallFont;
			float badgeHeight = badgeFont.GetHeight();
			g.SetFont(badgeFont);

			for (int spanIdx < mSpans.Count)
			{
				let span = mSpans[spanIdx];
				let entry = mEntries[span.mEntryIdx];
				bool isSelected = (span.mEntryIdx == mSelIdx) && (!entry.mIsPast);

				ewc.GetLineCharAtIdx(span.mTextIdx, let line, let lineChar);
				if (ewc.GetLineHeight(line) <= 0.1f)
					continue; // Collapsed
				ewc.GetTextCoordAtLineChar(line, lineChar, let x, let y);

				// Execution-order badge at the span's top-left, dipping into the line above
				String numStr = scope $"{span.mEntryIdx + 1}";
				float badgeWidth = badgeFont.GetWidth(numStr) + GS!(6);
				float badgeX = x;
				float badgeY = y + offset - badgeHeight;

				// Check if the badge would be clipped at the top
				Vector2 translated = g.mMatrix.Multiply(Vector2(badgeX, badgeY));
				if (translated.mY < g.mClipRect?.Top)
					badgeY = y + lineHeight;

				uint32 bgColor;
				uint32 textColor;
				if (entry.mIsPast)
				{
					bgColor = DarkTheme.COLOR_PAST_STEP_INTO_HILITE;
					textColor = DarkTheme.COLOR_TEXT_DISABLED;
				}
				else if (isSelected)
				{
					bgColor = DarkTheme.COLOR_STEP_INTO_OUTLINE;
					textColor = DarkTheme.COLOR_TEXT;
				}
				else
				{
					bgColor = DarkTheme.COLOR_STEP_INTO_HILITE;
					textColor = DarkTheme.COLOR_TEXT;
				}
				using (g.PushColor(bgColor))
					g.FillRect(badgeX, badgeY, badgeWidth, badgeHeight);
				using (g.PushColor(textColor))
					g.DrawString(numStr, badgeX, badgeY, .Centered, badgeWidth);
			}

			g.SetFont(ewc.mFont);
		}
	}
}
