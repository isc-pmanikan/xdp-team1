/// Loads the Boston 311 CSV extract into ProjA.ServiceRequest.
///
/// A utility class: %RegisteredObject, so it is never persisted. It holds the
/// parse-and-transform logic, kept separate from ProjA.ServiceRequest, which
/// owns the data model. Parsing and schema are different jobs.
///
/// Two ways in, because the two jobs are genuinely different:
///
///     Do ##class(ProjA.Loader).Run()               // bulk load, clears first
///     Do ##class(ProjA.Loader).Merge()             // fold in the Day 2 batch
///     Do ##class(ProjA.Loader).VerifyIdempotent()  // merge twice, prove no-op
///
/// Run() owns the table and starts from empty. Merge() does not: it reconciles a
/// batch against what is already stored, one case at a time. Both share the same
/// parsing and the same field mapping -- see ApplyRow().
Class ProjA.Loader Extends %RegisteredObject
{

/// Rows per transaction. Committing once per row makes transaction overhead
/// dominate; committing once for all 25,000 makes one failure lose everything.
Parameter BATCHSIZE = 1000;



/// Staged outside the repo on purpose. The IRIS server processes run as their own
/// uid (not the logged-in user), and ~/Documents is mode 700 on macOS, so a path
/// inside the checkout is unreadable to IRIS -- LinkToFile fails with a
/// permission error before a single row is parsed. /Users/Shared is world-readable
/// and, unlike /tmp, survives a reboot. Refresh it with:
///     cp src/Boston311-2026-Base.csv /Users/Shared/xdp-team1/data/
Parameter DEFAULTFILE = "/Users/Shared/xdp-team1/data/Boston311-2026-Base.csv";

/// The incremental batch: new requests, updated versions of requests already
/// loaded, and requests that were already received. Merged rather than loaded --
/// see MergeFile().
Parameter DAY2FILE = "/Users/Shared/xdp-team1/data/Boston311-2026-Day2.csv";

/// Convenience entry point: loads the default file, then prints the summary.
ClassMethod Run(maxRows As %Integer = 0) As %Status
{
	Set sc = ..LoadFile(..#DEFAULTFILE, 1, maxRows)
	If $$$ISERR(sc) Quit sc
	Write !
	Quit ##class(ProjA.ServiceRequest).Summary()
}

/// Convenience entry point for the incremental batch.
///     Do ##class(ProjA.Loader).Merge()
ClassMethod Merge() As %Status
{
	Quit ..MergeFile(..#DAY2FILE)
}

/// Reads the CSV and writes one ServiceRequest per row.
///   reload  - 1 clears the table first, so the load is repeatable
///   maxRows - stop after N successful rows (0 = all); useful for a smoke test
ClassMethod LoadFile(path As %String, reload As %Boolean = 1, maxRows As %Integer = 0) As %Status
{
	Set sc = ..OpenCsv(path, .stream)
	If $$$ISERR(sc) Quit sc

	Set sc = ..ReadHeader(stream, .idx, .columnCount)
	If $$$ISERR(sc) Quit sc

	If reload {
		Write "Clearing ProjA.ServiceRequest ...", !
		Do ##class(ProjA.ServiceRequest).%KillExtent()
	}

	Write "Loading from ", path, !
	Set (loaded, failed, rowNum, shown, clipped) = 0

	// The failure status is carried out in a variable rather than returned from
	// inside the Catch: ObjectScript does not allow QUIT with an argument inside
	// a Try or Catch block, because an argumentless QUIT there means "leave the
	// block". The bare Quit on the maxRows line below is fine -- it belongs to
	// the While loop, not the Try.
	Set abortStatus = ""

	Try {
		TSTART
		While 'stream.AtEnd {
			Set line = ..StripCR(stream.ReadLine())
			Set rowNum = rowNum + 1
			If $ZStrip(line, "<>W") = "" Continue

			Set fieldCount = ..SplitCsvLine(line, .f)
			If fieldCount '= columnCount {
				Set failed = failed + 1
				If shown < 10 {
					Write "  row ", rowNum, ": expected ", columnCount
					Write " fields, got ", fieldCount, " -- skipped", !
					Set shown = shown + 1
				}
				Continue
			}

			Set request = ##class(ProjA.ServiceRequest).%New()
			Do ..ApplyRow(request, .f, .idx, .clipped)

			Set sc = request.%Save()
			If $$$ISERR(sc) {
				Set failed = failed + 1
				If shown < 10 {
					Write "  row ", rowNum, ": ", $System.Status.GetErrorText(sc), !
					Set shown = shown + 1
				}
			} Else {
				Set loaded = loaded + 1
				If (loaded # ..#BATCHSIZE) = 0 {
					TCOMMIT
					TSTART
					Write "  ", loaded, " rows committed", !
				}
			}
			Kill request

			If maxRows, loaded >= maxRows Quit
		}
		TCOMMIT
	} Catch ex {
		If $TLevel > 0 TROLLBACK 1
		Write !, "Aborted at row ", rowNum, ": ", ex.DisplayString(), !
		Set abortStatus = ex.AsStatus()
	}

	// Dropping the last reference closes the underlying file handle.
	Set stream = ""

	If abortStatus '= "" Quit abortStatus

	Write !, "Done. Loaded ", loaded, " row(s), ", failed, " failure(s)."
	If failed > 10 Write " (only the first 10 were listed)"
	Write !
	If clipped > 0 Write clipped, " field(s) clipped to fit, each marked with [...]", !

	// The data now says something different about when "now" is.
	Write "As of: ", ##class(ProjA.ServiceRequest).RefreshAsOf(), !
	Quit $$$OK
}

// ---------------------------------------------------------------
//  Incremental load (the Day 2 batch)
// ---------------------------------------------------------------

/// Merges a batch of 311 activity into the table already loaded.
///
/// The batch mixes three kinds of row, and the point of this method is that it
/// does not need to be told which is which:
///
///   - a case ID not yet stored          -> inserted
///   - a stored case whose details moved -> updated in place
///   - a stored case that is unchanged   -> left exactly as it is
///
/// One record per case ID is preserved by looking each ID up through the unique
/// index CaseIdx and updating that object rather than saving a new one. The unique
/// index is also the backstop: were this logic wrong, %Save() would refuse the
/// duplicate rather than quietly storing two records for one case.
///
/// Re-running the same file is therefore a no-op, and deliberately so. "Unchanged"
/// is decided by comparing every stored property against the incoming row AFTER
/// both have been through the same parsing, so a row that merely LOOKS different
/// does not count: the Day 2 extract writes times as "8/13/26 15:09" where the
/// base extract wrote "8/13/26 3:09 PM", and all 50 of its repeat rows differ in
/// raw text while describing the identical instant. Comparing raw CSV text would
/// report 50 spurious updates on the first run and 50 more on every re-run.
///
/// Unchanged rows are not saved at all, rather than saved to the same values. The
/// visible difference is in the report -- a run that says "20 unchanged" is
/// evidence the state was left alone, where "100 updated" would not be.
ClassMethod MergeFile(path As %String, verbose As %Boolean = 1, Output stats) As %Status
{
	Kill stats
	Set (stats("inserted"), stats("updated"), stats("unchanged"), stats("skipped")) = 0
	Set (stats("repeated"), stats("entered"), stats("left"), stats("reopened")) = 0

	Set sc = ..OpenCsv(path, .stream)
	If $$$ISERR(sc) Quit sc

	Set sc = ..ReadHeader(stream, .idx, .columnCount)
	If $$$ISERR(sc) Quit sc

	Do ##class(ProjA.ServiceRequest).StateSnapshot(.before)
	Set tracked = ..TrackedProperties()

	If verbose {
		Write "Merging ", path, !
		Write "  against ", $FNumber(before("total"), ","), " stored request(s), as of ",
			before("asOf"), !, !
	}

	Set (rowNum, clipped, shown) = 0
	Set abortStatus = ""

	Try {
		TSTART
		While 'stream.AtEnd {
			Set line = ..StripCR(stream.ReadLine())
			Set rowNum = rowNum + 1
			If $ZStrip(line, "<>W") = "" Continue

			Set fieldCount = ..SplitCsvLine(line, .f)
			If (fieldCount '= columnCount) || '$IsValidNum(f(idx("case_enquiry_id"))) {
				Set stats("skipped") = stats("skipped") + 1
				If shown < 10 {
					Write "  row ", rowNum, ": unusable -- skipped", !
					Set shown = shown + 1
				}
				Continue
			}

			Set caseId = +f(idx("case_enquiry_id"))

			// A case ID repeated inside the batch itself. The later row wins, which
			// falls out of processing rows in order; it is counted so that a file
			// carrying contradictory rows for one case does not pass unremarked.
			If $Data(seen(caseId)) Set stats("repeated") = stats("repeated") + 1
			Set seen(caseId) = ""

			If '##class(ProjA.ServiceRequest).CaseIdxExists(caseId, .rowId) {
				Set request = ##class(ProjA.ServiceRequest).%New()
				Do ..ApplyRow(request, .f, .idx, .clipped)
				Set sc = request.%Save()
				If $$$ISERR(sc) {
					Set stats("skipped") = stats("skipped") + 1
					If shown < 10 {
						Write "  case ", caseId, ": ", $System.Status.GetErrorText(sc), !
						Set shown = shown + 1
					}
				} Else {
					Set stats("inserted") = stats("inserted") + 1
					If request.InAttentionQueue() {
						Set stats("entered") = stats("entered") + 1
						Set entered(caseId) = "new, already " _
							request.HoursOverdue() _ "h past its deadline"
					}
				}
				Kill request
				Continue
			}

			Set request = ##class(ProjA.ServiceRequest).%OpenId(rowId, 4, .sc)
			If '$IsObject(request) {
				Set stats("skipped") = stats("skipped") + 1
				If shown < 10 {
					Write "  case ", caseId, ": cannot open stored record -- skipped", !
					Set shown = shown + 1
				}
				Continue
			}

			// Snapshot before applying, so the two can be compared field by field.
			// $Property() reads by name, which keeps this loop independent of the
			// property list -- see TrackedProperties().
			Kill old
			For i = 1:1:$ListLength(tracked) {
				Set name = $List($List(tracked, i), 1)
				Set old(name) = $Property(request, name)
			}
			Set wasQueued = request.InAttentionQueue(), wasStatus = request.CaseStatus

			Do ..ApplyRow(request, .f, .idx, .clipped)

			Set changed = ""
			For i = 1:1:$ListLength(tracked) {
				Set spec = $List(tracked, i)
				Set name = $List(spec, 1)
				If ..ValueChanged(old(name), $Property(request, name), $List(spec, 2)) {
					Set changed = changed _ $Select(changed = "": "", 1: ", ") _ name
				}
			}

			If changed = "" {
				// Identical once parsed. Leave the stored record untouched: not
				// saving is what makes a re-run provably a no-op.
				Set stats("unchanged") = stats("unchanged") + 1
				Kill request
				Continue
			}

			Set sc = request.%Save()
			If $$$ISERR(sc) {
				Set stats("skipped") = stats("skipped") + 1
				If shown < 10 {
					Write "  case ", caseId, ": ", $System.Status.GetErrorText(sc), !
					Set shown = shown + 1
				}
			} Else {
				Set stats("updated") = stats("updated") + 1
				Set updates(caseId) = changed

				// A closed case being reopened is legitimate but suspicious enough
				// to name: it is also what a stale or mis-ordered batch looks like.
				If (wasStatus = "Closed") && (request.CaseStatus = "Open") {
					Set stats("reopened") = stats("reopened") + 1
				}
				Set nowQueued = request.InAttentionQueue()
				If 'wasQueued && nowQueued {
					Set stats("entered") = stats("entered") + 1
					Set entered(caseId) = "now " _ request.HoursOverdue() _ "h past its deadline"
				}
				If wasQueued && 'nowQueued {
					Set stats("left") = stats("left") + 1
					Set left(caseId) = wasStatus _ " -> " _ request.CaseStatus
				}
			}
			Kill request
		}
		TCOMMIT
	} Catch ex {
		If $TLevel > 0 TROLLBACK 1
		Write !, "Aborted at row ", rowNum, ": ", ex.DisplayString(), !
		Set abortStatus = ex.AsStatus()
	}

	Set stream = ""
	If abortStatus '= "" Quit abortStatus

	Set stats("clipped") = clipped
	Set stats("rows") = rowNum

	// Newer activity moves the as-of instant, so recompute it before measuring the
	// after state -- otherwise the queue would be counted against a "now" that
	// predates the batch just merged.
	Do ##class(ProjA.ServiceRequest).RefreshAsOf()
	Do ##class(ProjA.ServiceRequest).StateSnapshot(.after)

	If verbose Do ..ReportMerge(.stats, .before, .after, .updates, .entered, .left)
	Quit $$$OK
}

/// Prints what a merge did. Separate from MergeFile() so the merge itself can be
/// called quietly (VerifyIdempotent() does exactly that).
ClassMethod ReportMerge(ByRef stats, ByRef before, ByRef after, ByRef updates, ByRef entered, ByRef left) As %Status
{
	Write "  inserted   ", $Justify(stats("inserted"), 5), "  case ID(s) not seen before", !
	Write "  updated    ", $Justify(stats("updated"), 5), "  stored case(s) whose details moved", !
	Write "  unchanged  ", $Justify(stats("unchanged"), 5), "  already current -- not rewritten", !
	If stats("skipped") > 0 {
		Write "  skipped    ", $Justify(stats("skipped"), 5), "  unusable row(s)", !
	}
	If stats("repeated") > 0 {
		Write "  note: ", stats("repeated"), " case ID(s) appeared more than once in the file;",
			" the last row won", !
	}
	If stats("reopened") > 0 {
		Write "  note: ", stats("reopened"), " closed case(s) were reopened by this batch", !
	}
	If stats("clipped") > 0 {
		Write "  note: ", stats("clipped"), " field(s) clipped to fit", !
	}

	Write !, "Attention queue: ", stats("entered"), " entered, ", stats("left"), " left", !
	Do ..ListCases(.entered, "  IN  ", 8)
	Do ..ListCases(.left, "  OUT ", 8)

	Write !, "Effect on the application", !
	Do ..DeltaLine("total requests", before("total"), after("total"))
	Do ..DeltaLine("open", before("open"), after("open"))
	Do ..DeltaLine("closed", before("closed"), after("closed"))
	Do ..DeltaLine("past SLA, still open", before("queue"), after("queue"))
	If before("asOf") '= after("asOf") {
		Write "  as of                 ", before("asOf"), "  ->  ", after("asOf"), !
		// Worth spelling out: this alone moves the queue, independently of the rows
		// merged, because a day's worth of deadlines fall due in between.
		Write "    (the batch carries later activity, so 'now' advanced with it --", !
		Write "     part of the queue change above is deadlines falling due, not new rows)", !
	}
	Quit $$$OK
}

/// One before/after row of the effect table.
ClassMethod DeltaLine(label As %String, before As %Integer, after As %Integer) As %Status
{
	Set delta = after - before
	Write "  ", $Justify(label, -22), $Justify($FNumber(before, ","), 8),
		"  ->", $Justify($FNumber(after, ","), 8), "   ",
		$Select(delta > 0: "+", 1: ""), $FNumber(delta, ","), !
	Quit $$$OK
}

/// Prints up to limit entries of caseId -> note, then how many were withheld.
ClassMethod ListCases(ByRef cases, prefix As %String, limit As %Integer) As %Status
{
	Set caseId = "", n = 0
	For {
		Set caseId = $Order(cases(caseId))
		If caseId = "" Quit
		Set n = n + 1
		If n <= limit Write prefix, caseId, "  ", cases(caseId), !
	}
	If n > limit Write prefix, "... and ", n - limit, " more", !
	Quit $$$OK
}

/// Merges the file twice and checks the second pass changed nothing.
///
/// The spec asks for this explicitly ("try processing the same Day 2 file a second
/// time"), so it is written down as a check rather than left as something to do by
/// hand and eyeball. Pass means: the second run inserted and updated nothing, and
/// the four state counts are identical either side of it.
ClassMethod VerifyIdempotent(path As %String = {..#DAY2FILE}) As %Status
{
	Write "=== PASS 1 ===", !
	Set sc = ..MergeFile(path, 1, .first)
	If $$$ISERR(sc) Quit sc
	Do ##class(ProjA.ServiceRequest).StateSnapshot(.mid)

	Write !, "=== PASS 2 (same file again) ===", !
	Set sc = ..MergeFile(path, 1, .second)
	If $$$ISERR(sc) Quit sc
	Do ##class(ProjA.ServiceRequest).StateSnapshot(.end)

	Write !, "=== IDEMPOTENCY CHECK ===", !
	Set failures = 0
	Do ..Assert("pass 2 inserted nothing", second("inserted") = 0, .failures)
	Do ..Assert("pass 2 updated nothing", second("updated") = 0, .failures)
	Do ..Assert("pass 2 saw every row as already current",
		second("unchanged") = (first("inserted") + first("updated") + first("unchanged")), .failures)
	For key = "total", "open", "closed", "queue", "asOf" {
		Do ..Assert("state unchanged: " _ key, mid(key) = end(key), .failures)
	}

	Write !
	If failures = 0 {
		Write "PASS -- reprocessing the file was a no-op.", !
	} Else {
		Write "FAIL -- ", failures, " check(s) failed.", !
	}
	Quit $Select(failures = 0: $$$OK, 1: $$$ERROR($$$GeneralError, "idempotency check failed"))
}

/// Prints one check result and counts the failures.
ClassMethod Assert(label As %String, condition As %Boolean, ByRef failures As %Integer) As %Status
{
	Write "  ", $Select(condition: "ok  ", 1: "FAIL"), "  ", label, !
	If 'condition Set failures = $Get(failures, 0) + 1
	Quit $$$OK
}

// ---------------------------------------------------------------
//  Parsing and transformation helpers
// ---------------------------------------------------------------

/// Opens a CSV for reading as UTF-8, line by line.
ClassMethod OpenCsv(path As %String, Output stream As %Stream.FileCharacter) As %Status
{
	Set stream = ##class(%Stream.FileCharacter).%New()
	Set sc = stream.LinkToFile(path)
	If $$$ISERR(sc) {
		Write "Cannot open ", path, ": ", $System.Status.GetErrorText(sc), !
		Quit sc
	}
	// LineTerminator is set to bare LF and any trailing CR stripped per line, so
	// this works for CRLF and LF alike.
	Set stream.TranslateTable = "UTF8"
	Set stream.LineTerminator = $Char(10)
	Quit $$$OK
}

/// Reads the header row into a column-name -> position map.
///
/// The map exists so that a change in column ORDER in a future extract cannot
/// silently corrupt a load: every field is fetched by name below, never by
/// position.
ClassMethod ReadHeader(stream As %Stream.FileCharacter, Output idx, Output columnCount As %Integer) As %Status
{
	Kill idx
	Set headerLine = ..StripBom(..StripCR(stream.ReadLine()))
	Set columnCount = ..SplitCsvLine(headerLine, .headerFields)
	For i = 1:1:columnCount {
		Set idx($ZConvert(..CleanText(headerFields(i)), "L")) = i
	}
	Set sc = ..CheckColumns(.idx, .missing)
	If $$$ISERR(sc) Write "CSV is missing expected column(s): ", missing, !
	Quit sc
}

/// Copies one parsed CSV row onto a ServiceRequest, new or already stored.
///
/// Shared by LoadFile() and MergeFile() deliberately. Two copies of 29 field
/// assignments would drift, and the merge would then start deciding "changed" by
/// comparing stored values against values parsed slightly differently -- which
/// looks like data churn and is actually a bug in this file.
ClassMethod ApplyRow(request As ProjA.ServiceRequest, ByRef f, ByRef idx, ByRef clipped) As %Status
{
	Set request.CaseEnquiryId = +f(idx("case_enquiry_id"))
	Set request.OpenedDate = ..ToTimeStamp(f(idx("open_dt")))
	Set request.SlaTargetDate = ..ToTimeStamp(f(idx("sla_target_dt")))
	Set request.ClosedDate = ..ToTimeStamp(f(idx("closed_dt")))
	Set request.OnTime = ..CleanText(f(idx("on_time")))
	Set request.CaseStatus = ..CleanText(f(idx("case_status")))
	// Free text and URLs are clipped to their declared MAXLEN. Keep these
	// lengths in step with ProjA.ServiceRequest if you ever change them.
	Set request.ClosureReason = ..ClipText(f(idx("closure_reason")), 4000, .clipped)
	Set request.CaseTitle = ..ClipText(f(idx("case_title")), 250, .clipped)
	Set request.Subject = ..CleanText(f(idx("subject")))
	Set request.Reason = ..CleanText(f(idx("reason")))
	Set request.RequestType = ..CleanText(f(idx("type")))
	Set request.Queue = ..CleanText(f(idx("queue")))
	Set request.Department = ..CleanText(f(idx("department")))
	Set request.SubmittedPhoto = ..ClipText(f(idx("submitted_photo")), 500, .clipped)
	Set request.ClosedPhoto = ..ClipText(f(idx("closed_photo")), 500, .clipped)
	Set request.Location = ..ClipText(f(idx("location")), 300, .clipped)
	Set request.FireDistrict = ..CleanText(f(idx("fire_district")))
	Set request.PwdDistrict = ..CleanText(f(idx("pwd_district")))
	Set request.CityCouncilDistrict = ..CleanText(f(idx("city_council_district")))
	Set request.PoliceDistrict = ..CleanText(f(idx("police_district")))
	Set request.Neighborhood = ..CleanText(f(idx("neighborhood")))
	Set request.NeighborhoodServicesDistrict = ..CleanText(f(idx("neighborhood_services_district")))
	Set request.Ward = ..NormalizeWard(f(idx("ward")))
	Set request.Precinct = ..CleanText(f(idx("precinct")))
	Set request.StreetName = ..ClipText(f(idx("location_street_name")), 200, .clipped)
	Set request.Zipcode = ..PadZip(f(idx("location_zipcode")))
	Set request.Latitude = ..ToNumber(f(idx("latitude")))
	Set request.Longitude = ..ToNumber(f(idx("longitude")))
	Set request.Source = ..CleanText(f(idx("source")))
	// geom_4326 is deliberately dropped: it is a long WKB hex blob that
	// duplicates latitude/longitude and would roughly double table size.
	Quit $$$OK
}

/// The stored properties of ProjA.ServiceRequest: a $List of $ListBuild(name,
/// isFloatingPoint) pairs.
///
/// Read from the class dictionary rather than written out here. A hand-kept list
/// is the kind that goes stale silently: add a property, forget the list, and the
/// merge stops noticing when that property changes -- a bug with no symptom except
/// wrong data. Calculated, transient and private properties are excluded because
/// they are not what "did this record change" means.
///
/// The type comes along because floating-point properties cannot be compared as
/// text -- see ValueChanged().
ClassMethod TrackedProperties() As %List
{
	Set props = ""
	Set statement = ##class(%SQL.Statement).%New()
	Set sc = statement.%Prepare(
		"SELECT Name, Type FROM %Dictionary.CompiledProperty "_
		"WHERE parent = 'ProjA.ServiceRequest' "_
		"  AND Calculated = 0 AND Transient = 0 AND Private = 0 "_
		"ORDER BY Name")
	If $$$ISERR(sc) Quit ""
	Set resultSet = statement.%Execute()
	While resultSet.%Next() {
		// Reduced to a bare type name -- the dictionary reports %Library.Double
		// where the class source says %Double -- so that every spelling of the
		// inexact numerics is recognised.
		Set type = $Translate($Piece(resultSet.%GetData(2), ".", *), "%", "")
		Set isFloat = (",Double,Float,Numeric,Decimal," [ (","_type_","))
		Set props = props _ $ListBuild($ListBuild(resultSet.%GetData(1), isFloat))
	}
	Quit props
}

/// Has one property genuinely changed between the stored and the incoming value?
///
/// Floating-point properties must be compared as numbers, not as text. A latitude
/// read back from disk is the decimal expansion of an IEEE binary double --
/// 42.359472390000000531 -- while the same coordinate parsed out of the CSV is
/// 42.35947239. Those are one number and two strings, so comparing text reported
/// every row that carries coordinates as changed: the first merge claimed 50
/// updates where 20 of those rows were untouched duplicates, and re-running the
/// same file claimed 100 updates instead of being the no-op it actually was.
///
/// Nothing was written wrongly by that -- the values saved were the values already
/// stored -- but a merge that cannot tell "new information" from "same information,
/// printed differently" cannot report honestly on what it did, and idempotency
/// stops being demonstrable.
ClassMethod ValueChanged(before As %String, after As %String, isFloat As %Boolean) As %Boolean
{
	If 'isFloat Quit (before '= after)
	// A blank coordinate means missing, not zero, and $Double("") is 0 -- so an
	// empty either side is compared as text to keep those two distinguishable.
	If (before = "") || (after = "") Quit (before '= after)
	Quit ($Double(before) '= $Double(after))
}

/// Removes a leading UTF-8 byte-order mark.
///
/// Boston311-2026-Base.csv has none; Boston311-2026-Day2.csv has one. Decoded
/// through the UTF8 translate table it arrives as a single $Char(65279) glued to
/// the front of the first header name, so "case_enquiry_id" is no longer equal to
/// "case_enquiry_id" -- CheckColumns() then rejects a file whose columns are all
/// present, naming the one column that is most obviously there. Cheap to strip,
/// expensive to work out.
ClassMethod StripBom(line As %String) As %String
{
	If $Ascii(line) = 65279 Quit $Extract(line, 2, *)
	Quit line
}

/// Removes one trailing CR.
///
/// LineTerminator is set to bare LF above, so on a CRLF file every line comes
/// back with a CR still glued to its end. Left in place, that CR lands on the
/// last column of every row -- Source would become "Citizens Connect App"_CR,
/// which compares and groups as a distinct value. Splitting on CRLF instead
/// would break if the file were ever saved with LF endings, so the terminator
/// stays permissive and the CR is stripped here.
ClassMethod StripCR(line As %String) As %String
{
	If $Extract(line, *) = $Char(13) Quit $Extract(line, 1, *-1)
	Quit line
}

/// Every column this loader reads. Fail loudly and up front if the extract
/// does not have them, rather than half-loading a table.
ClassMethod CheckColumns(ByRef idx, Output missing As %String) As %Status
{
	Set missing = ""
	Set expected = "case_enquiry_id,open_dt,sla_target_dt,closed_dt,on_time,case_status,"_
		"closure_reason,case_title,subject,reason,type,queue,department,submitted_photo,"_
		"closed_photo,location,fire_district,pwd_district,city_council_district,"_
		"police_district,neighborhood,neighborhood_services_district,ward,precinct,"_
		"location_street_name,location_zipcode,latitude,longitude,source"
	For i = 1:1:$Length(expected, ",") {
		Set name = $Piece(expected, ",", i)
		If '$Data(idx(name)) {
			Set missing = missing_$Select(missing = "": "", 1: ", ")_name
		}
	}
	If missing '= "" Quit $$$ERROR($$$GeneralError, "missing columns: "_missing)
	Quit $$$OK
}

/// Splits one CSV line, honouring double-quoted fields and "" escapes.
/// This extract happens to have no commas inside quotes, but a parser that
/// only used $Piece would silently corrupt any future file that did.
ClassMethod SplitCsvLine(line As %String, Output fields As %String) As %Integer
{
	Kill fields
	Set count = 0, current = "", inQuotes = 0
	Set length = $Length(line), i = 1
	While i <= length {
		Set char = $Extract(line, i)
		If inQuotes {
			If char = """" {
				If $Extract(line, i + 1) = """" {
					Set current = current_""""
					Set i = i + 1
				} Else {
					Set inQuotes = 0
				}
			} Else {
				Set current = current_char
			}
		} Else {
			If char = """" {
				Set inQuotes = 1
			} ElseIf char = "," {
				Set count = count + 1, fields(count) = current, current = ""
			} Else {
				Set current = current_char
			}
		}
		Set i = i + 1
	}
	Set count = count + 1, fields(count) = current
	Quit count
}

/// "8/13/26 10:30 PM" -> "2026-08-13 22:30:00"
///
/// The source format is not a valid %TimeStamp, so this conversion is what
/// makes date arithmetic and ORDER BY work at all. Every date in the extract
/// matches M/D/YY h:mm AM/PM; anything that does not is returned as empty
/// rather than guessed at.
///
/// Assumption: the two-digit year is 20YY. Correct for this 2026 extract,
/// but revisit if you ever load historical data spanning 1900s.
ClassMethod ToTimeStamp(raw As %String) As %TimeStamp
{
	Set raw = $ZStrip(raw, "<>W")
	If raw = "" Quit ""

	Set datePart = $Piece(raw, " ", 1)
	Set timePart = $Piece(raw, " ", 2)
	Set meridiem = $ZConvert($Piece(raw, " ", 3), "U")

	Set month = +$Piece(datePart, "/", 1)
	Set day = +$Piece(datePart, "/", 2)
	Set year = +$Piece(datePart, "/", 3)
	If year < 100 Set year = 2000 + year

	Set hour = +$Piece(timePart, ":", 1)
	Set minute = +$Piece(timePart, ":", 2)
	Set second = +$Piece(timePart, ":", 3)

	If (meridiem = "PM") && (hour < 12) Set hour = hour + 12
	If (meridiem = "AM") && (hour = 12) Set hour = 0

	// Reject anything implausible instead of storing a bad timestamp.
	If (month < 1) || (month > 12) || (day < 1) || (day > 31) Quit ""
	If (hour > 23) || (minute > 59) || (second > 59) Quit ""
	If (year < 1900) || (year > 2200) Quit ""

	Quit year_"-"_..Pad2(month)_"-"_..Pad2(day)_" "_
		..Pad2(hour)_":"_..Pad2(minute)_":"_..Pad2(second)
}

/// 7 -> "07"
ClassMethod Pad2(number As %Integer) As %String
{
	Quit $Translate($Justify(number, 2), " ", "0")
}

/// CleanText, then truncate to maxLen if still too long.
///
/// Used only on the free-text and URL columns. Those are written by people and
/// by generators, so any MAXLEN is a guess, and losing a whole service request
/// because someone wrote a long closure note is the wrong trade -- a clipped
/// note still tells you what happened. The coded columns (department, ward, the
/// districts) deliberately do NOT go through here: they come from fixed
/// vocabularies, so an overflow there means the extract format changed, and
/// that should fail loudly rather than be quietly shortened.
///
/// The trailing marker keeps a clipped value honest, so nobody later reads a
/// sentence that stops mid-word as the whole story.
ClassMethod ClipText(value As %String, maxLen As %Integer, ByRef counter As %Integer) As %String
{
	Set value = ..CleanText(value)
	If $Length(value) <= maxLen Quit value
	Set counter = $Get(counter, 0) + 1
	Quit $Extract(value, 1, maxLen - 6)_" [...]"
}

/// Trims, decodes HTML entities, and collapses runs of spaces.
/// &amp; is decoded last so that "&amp;lt;" does not become "<".
ClassMethod CleanText(value As %String) As %String
{
	Set value = $ZStrip(value, "<>W")
	If value = "" Quit ""
	Set value = $Replace(value, "&quot;", """")
	Set value = $Replace(value, "&#39;", "'")
	Set value = $Replace(value, "&apos;", "'")
	Set value = $Replace(value, "&lt;", "<")
	Set value = $Replace(value, "&gt;", ">")
	Set value = $Replace(value, "&amp;", "&")
	While value [ "  " {
		Set value = $Replace(value, "  ", " ")
	}
	Quit $ZStrip(value, "<>W")
}

/// The source mixes "Ward 1" and bare "3". Store the number either way.
ClassMethod NormalizeWard(value As %String) As %String
{
	Set value = ..CleanText(value)
	If $ZConvert($Extract(value, 1, 5), "L") = "ward " {
		Set value = $ZStrip($Extract(value, 6, *), "<>W")
	}
	Quit value
}

/// The extract has already lost the leading zero ("2128"). Put it back so
/// zip codes compare and group correctly as strings.
ClassMethod PadZip(value As %String) As %String
{
	Set value = $ZStrip(..CleanText(value), "*E'N")
	If value = "" Quit ""
	Quit $Extract("00000"_value, *-4, *)
}

/// Empty string rather than 0 for a blank coordinate: 0,0 is a real location
/// in the Gulf of Guinea and would quietly poison any mapping or distance work.
ClassMethod ToNumber(value As %String) As %String
{
	Set value = $ZStrip(value, "<>W")
	If value = "" Quit ""
	If '$IsValidNum(value) Quit ""
	Quit +value
}

}
