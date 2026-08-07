using System;
using System.Collections;
using Beefy.gfx;
using Beefy.theme.dark;
using IDE.Debugger;

namespace IDE.ui
{
	// Inline call-token highlighting for "Step into Specific": highlights the call tokens on the
	// paused line, arrow keys / Tab cycle the selection, Enter or the step hotkeys confirm.
	// TryCreate returns null when the debugger candidates can't all be matched to source tokens,
	// in which case the caller falls back to the popup selector.
	class StepIntoSpecificHilite
	{
		public struct Span
		{
			public int32 mTextIdx; // Absolute index into mData.mText
			public int32 mLength;
			public int mCallAddr;
			public bool mIsPast;
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

		public SourceEditWidgetContent mEditWidgetContent;
		public List<Span> mSpans = new .() ~ delete _; // Sorted by mTextIdx (source order)
		public int32 mSelIdx;
		public int32 mDebuggerContinueIdx;
		public int32 mTextVersionId;
		public int32 mCallStackIdx;
		public int32 mUpdateCnt;

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

		public static StepIntoSpecificHilite TryCreate(SourceEditWidgetContent ewc, List<DebugManager.LineCall> calls)
		{
			int line = ewc.CursorLineAndColumn.mLine;

			String lineText = scope .();
			List<Token> tokens = scope .();
			CollectTokens(ewc, line, lineText, tokens);

			List<Span> spans = scope .();
			for (var call in calls)
			{
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
								span.mCallAddr = call.mAddr;
								span.mIsPast = call.mIsPastAddr;
								spans.Add(span);
								matched = true;
								break;
							}
							if (matched)
								break;
						}
					}
				}

				if (!matched)
				{
					// A past call is informational only - not visualizing it hides no target.
					// An unmatched selectable candidate however forces the popup fallback.
					if (call.mIsPastAddr)
						continue;
					return null;
				}
			}

			// The first non-past call is the next one to execute - it becomes the initial selection
			int firstAddr = 0;
			for (var call in calls)
			{
				if (!call.mIsPastAddr)
				{
					firstAddr = call.mAddr;
					break;
				}
			}
			if (firstAddr == 0)
				return null; // Only past calls - nothing to step into

			spans.Sort(scope (lhs, rhs) => lhs.mTextIdx <=> rhs.mTextIdx);

			var hilite = new StepIntoSpecificHilite();
			hilite.mEditWidgetContent = ewc;
			hilite.mSpans.AddRange(spans);
			hilite.mDebuggerContinueIdx = gApp.mDebuggerContinueIdx;
			hilite.mTextVersionId = ewc.mData.mCurTextVersionId;
			hilite.mCallStackIdx = gApp.mDebugger.mActiveCallStackIdx;
			for (int spanIdx < hilite.mSpans.Count)
			{
				if (hilite.mSpans[spanIdx].mCallAddr == firstAddr)
				{
					hilite.mSelIdx = (int32)spanIdx;
					break;
				}
			}
			return hilite;
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
			int count = mSpans.Count;
			int idx = mSelIdx;
			for (int i < count)
			{
				idx = (((idx + dir) % count) + count) % count;
				if (!mSpans[idx].mIsPast)
				{
					mSelIdx = (int32)idx;
					return;
				}
			}
		}

		public void Submit()
		{
			if ((mSelIdx < 0) || (mSelIdx >= mSpans.Count) || (mSpans[mSelIdx].mIsPast))
				return;
			int addr = mSpans[mSelIdx].mCallAddr;
			// Cancel deletes 'this' - no member access allowed after this point
			mEditWidgetContent.CancelStepIntoSpecificHilite();
			gApp.StepIntoSpecific(addr);
		}

		public void Draw(Graphics g)
		{
			var ewc = mEditWidgetContent;
			float height = ewc.mFont.GetHeight();
			float offset = ewc.GetTextOffset();
			for (int spanIdx < mSpans.Count)
			{
				let span = mSpans[spanIdx];
				ewc.GetLineCharAtIdx(span.mTextIdx, var line, var lineChar);
				if (ewc.GetLineHeight(line) <= 0.1f)
					continue; // Collapsed
				ewc.GetTextCoordAtLineChar(line, lineChar, var x, var y);
				ewc.GetTextCoordAtLineChar(line, lineChar + span.mLength, var endX, var endY);
				float width = endX - x;

				if (span.mIsPast)
				{
					using (g.PushColor(0x30F6CCFF))
						g.FillRect(x, y + offset, width, height);
				}
				else if (spanIdx == mSelIdx)
				{
					using (g.PushColor(0x58BD37D3))
						g.FillRect(x, y + offset, width, height);
					using (g.PushColor(0xFFBD37D3))
						g.OutlineRect(x, y + offset, width, height, GS!(1));
				}
				else
				{
					using (g.PushColor(0x40BD37D3))
						g.FillRect(x, y + offset, width, height);
				}
			}
		}
	}
}
