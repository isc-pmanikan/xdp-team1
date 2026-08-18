/// Loads the Boston 311 CSV extract into ProjA.ServiceRequest.
///
/// A utility class: %RegisteredObject, so it is never persisted. It holds the
/// parse-and-transform logic, kept separate from ProjA.ServiceRequest, which
/// owns the data model. Parsing and schema are different jobs.
///
/// Run it with:
///     Do ##class(ProjA.Loader).Run()
Class ProjA.Loader Extends %RegisteredObject
{

/// Rows per transaction. Committing once per row makes transaction overhead
/// dominate; committing once for all 25,000 makes one failure lose everything.
Parameter BATCHSIZE = 1000;

Parameter DEFAULTFILE = "C:\Users\avergara\Documents\Intersystems\src\Boston311-2026-Base.csv";

/// Convenience entry point: loads the default file, then prints the summary.
ClassMethod Run(maxRows As %Integer = 0) As %Status
{
	Set sc = ..LoadFile(..#DEFAULTFILE, 1, maxRows)
	If $$$ISERR(sc) Quit sc
	Write !
	Quit ##class(ProjA.ServiceRequest).Summary()
}

/// Reads the CSV and writes one ServiceRequest per row.
///   reload  - 1 clears the table first, so the load is repeatable
///   maxRows - stop after N successful rows (0 = all); useful for a smoke test
ClassMethod LoadFile(path As %String, reload As %Boolean = 1, maxRows As %Integer = 0) As %Status
{
	Set stream = ##class(%Stream.FileCharacter).%New()
	Set sc = stream.LinkToFile(path)
	If $$$ISERR(sc) {
		Write "Cannot open ", path, ": ", $System.Status.GetErrorText(sc), !
		Quit sc
	}
	// The file is UTF-8 with no BOM. LineTerminator is set to bare LF and any
	// trailing CR stripped per line, so this works for CRLF and LF alike.
	Set stream.TranslateTable = "UTF8"
	Set stream.LineTerminator = $Char(10)

	// --- header: build a column-name -> position map so that a change in
	// --- column order in a future extract does not silently corrupt the load.
	Set headerLine = ..StripCR(stream.ReadLine())
	Set columnCount = ..SplitCsvLine(headerLine, .headerFields)
	Kill idx
	For i = 1:1:columnCount {
		Set idx($ZConvert(..CleanText(headerFields(i)), "L")) = i
	}

	Set sc = ..CheckColumns(.idx, .missing)
	If $$$ISERR(sc) {
		Write "CSV is missing expected column(s): ", missing, !
		Quit sc
	}

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
	Quit $$$OK
}

// ---------------------------------------------------------------
//  Parsing and transformation helpers
// ---------------------------------------------------------------

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
