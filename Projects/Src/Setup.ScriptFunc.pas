unit Setup.ScriptFunc;

{
  Inno Setup
  Copyright (C) 1997-2024 Jordan Russell
  Portions by Martijn Laan
  For conditions of distribution and use, see LICENSE.TXT.

  Script support functions (run time - used by Setup)
}

interface

uses
  uPSRuntime;

procedure ScriptFuncLibraryRegister_R(ScriptInterpreter: TPSExec);

implementation

uses
  Windows, Shared.ScriptFunc,
  Forms, uPSUtils, SysUtils, Classes, Graphics, Controls, TypInfo, ActiveX, Generics.Collections,
  PathFunc, BrowseFunc, MD5, SHA1, SHA256, ASMInline, BitmapImage,
  Shared.Struct, Setup.ScriptDlg, Setup.MainForm, Setup.MainFunc, Shared.CommonFunc.Vcl,
  Shared.CommonFunc, Shared.FileClass, SetupLdrAndSetup.RedirFunc,
  Setup.Install, SetupLdrAndSetup.InstFunc, Setup.InstFunc, Setup.InstFunc.Ole,
  SetupLdrAndSetup.Messages, Shared.SetupMessageIDs, Setup.NewDiskForm,
  Setup.WizardForm, Shared.VerInfoFunc, Shared.SetupTypes, Shared.SetupSteps,
  Shared.Int64Em, Setup.LoggingFunc, Setup.SetupForm, Setup.RegDLL, Setup.Helper,
  Setup.SpawnClient, Setup.UninstallProgressForm, Setup.DotNetFunc,
  Shared.DotNetVersion, Setup.MsiFunc, Compression.SevenZipDecoder,
  Setup.DebugClient;

var
  ScaleBaseUnitsInitialized: Boolean;
  ScaleBaseUnitX, ScaleBaseUnitY: Integer;

procedure NoSetupFuncError(const C: AnsiString); overload;
begin
  InternalError(Format('Cannot call "%s" function during Setup', [C]));
end;

procedure NoUninstallFuncError(const C: AnsiString); overload;
begin
  InternalError(Format('Cannot call "%s" function during Uninstall', [C]));
end;

procedure NoSetupFuncError(const C: UnicodeString); overload;
begin
  InternalError(Format('Cannot call "%s" function during Setup', [C]));
end;

procedure NoUninstallFuncError(const C: UnicodeString); overload;
begin
  InternalError(Format('Cannot call "%s" function during Uninstall', [C]));
end;

function GetMainForm: TMainForm;
begin
  Result := MainForm;
  if Result = nil then
    InternalError('An attempt was made to access MainForm before it has been created'); 
end;

function GetWizardForm: TWizardForm;
begin
  Result := WizardForm;
  if Result = nil then
    InternalError('An attempt was made to access WizardForm before it has been created'); 
end;

function GetUninstallProgressForm: TUninstallProgressForm;
begin
  Result := UninstallProgressForm;
  if Result = nil then
    InternalError('An attempt was made to access UninstallProgressForm before it has been created');
end;

function GetMsgBoxCaption: String;
var
  ID: TSetupMessageID;
begin
  if IsUninstaller then
    ID := msgUninstallAppTitle
  else
    ID := msgSetupAppTitle;
  Result := SetupMessages[ID];
end;

procedure InitializeScaleBaseUnits;
var
  Font: TFont;
begin
  if ScaleBaseUnitsInitialized then
    Exit;
  Font := TFont.Create;
  try
    SetFontNameSize(Font, LangOptions.DialogFontName, LangOptions.DialogFontSize,
      '', 8);
    CalculateBaseUnitsFromFont(Font, ScaleBaseUnitX, ScaleBaseUnitY);
  finally
    Font.Free;
  end;
  ScaleBaseUnitsInitialized := True;
end;

function IsProtectedSrcExe(const Filename: String): Boolean;
begin
  if (MainForm = nil) or (MainForm.CurStep < ssInstall) then begin
    var ExpandedFilename := PathExpand(Filename);
    Result := PathCompare(ExpandedFilename, SetupLdrOriginalFilename) = 0;
  end else
    Result := False;
end;

{---}

type
  TPSStackHelper = class helper for TPSStack
  private
    function GetArray(const ItemNo, FieldNo: Longint; out N: Integer): TPSVariantIFC;
    function SetArray(const ItemNo, FieldNo: Longint; const N: Integer): TPSVariantIFC; overload;
  public
    type
      TArrayOfInteger = array of Integer;
      TArrayOfString = array of String;
      TArrayBuilder = record
        Arr: TPSVariantIFC;
        I: Integer;
        procedure Add(const Data: String);
      end;
      TArrayEnumerator = record
        Arr: TPSVariantIFC;
        N, I: Integer;
        function HasNext: Boolean;
        function Next: String;
      end;
    function GetIntArray(const ItemNo: Longint; const FieldNo: Longint = -1): TArrayOfInteger;
    function GetProc(const ItemNo: Longint; const Exec: TPSExec): TMethod;
    function GetStringArray(const ItemNo: Longint; const FieldNo: Longint = -1): TArrayOfString;
    function InitArrayBuilder(const ItemNo: LongInt; const FieldNo: Longint = -1): TArrayBuilder;
    function InitArrayEnumerator(const ItemNo: LongInt; const FieldNo: Longint = -1): TArrayEnumerator;
    procedure SetArray(const ItemNo: Longint; const Data: TArray<String>; const FieldNo: Longint = -1); overload;
    procedure SetArray(const ItemNo: Longint; const Data: TStrings; const FieldNo: Longint = -1); overload;
    procedure SetInt(const ItemNo: Longint; const Data: Integer; const FieldNo: Longint = -1);
  end;

function TPSStackHelper.GetArray(const ItemNo, FieldNo: Longint;
  out N: Integer): TPSVariantIFC;
begin
  if FieldNo >= 0 then
    Result := NewTPSVariantRecordIFC(Items[ItemNo], FieldNo)
  else
    Result := NewTPSVariantIFC(Items[ItemNo], True);
  N := PSDynArrayGetLength(Pointer(Result.Dta^), Result.aType);
end;

function TPSStackHelper.SetArray(const ItemNo, FieldNo: Longint;
  const N: Integer): TPSVariantIFC;
begin
  if FieldNo >= 0 then
    Result := NewTPSVariantRecordIFC(Items[ItemNo], FieldNo)
  else
    Result := NewTPSVariantIFC(Items[ItemNo], True);
  PSDynArraySetLength(Pointer(Result.Dta^), Result.aType, N);
end;

function TPSStackHelper.GetIntArray(const ItemNo, FieldNo: Longint): TArrayOfInteger;
begin
  var N: Integer;
  var Arr := GetArray(ItemNo, FieldNo, N);
  SetLength(Result, N);
  for var I := 0 to N-1 do
    Result[I] := VNGetInt(PSGetArrayField(Arr, I));
end;

function TPSStackHelper.GetProc(const ItemNo: Longint; const Exec: TPSExec): TMethod;
begin
  var P := PPSVariantProcPtr(Items[ItemNo]);
  { ProcNo 0 means nil was passed by the script and GetProcAsMethod will then return a (nil, nil) TMethod }
  Result := Exec.GetProcAsMethod(P.ProcNo);
end;

function TPSStackHelper.GetStringArray(const ItemNo, FieldNo: Longint): TArrayOfString;
begin
  var N: Integer;
  var Arr := GetArray(ItemNo, FieldNo, N);
  SetLength(Result, N);
  for var I := 0 to N-1 do
    Result[I] := VNGetString(PSGetArrayField(Arr, I));
end;

function TPSStackHelper.InitArrayBuilder(const ItemNo, FieldNo: Longint): TArrayBuilder;
begin
  Result.Arr := SetArray(ItemNo, FieldNo, 0);
  Result.I := 0;
end;

procedure TPSStackHelper.TArrayBuilder.Add(const Data: String);
begin
  PSDynArraySetLength(Pointer(Arr.Dta^), Arr.aType, I+1);
  VNSetString(PSGetArrayField(Arr, I), Data);
  Inc(I);
end;

function TPSStackHelper.InitArrayEnumerator(const ItemNo, FieldNo: Longint): TArrayEnumerator;
begin
  Result.Arr := GetArray(ItemNo, FieldNo, Result.N);
  Result.I := 0;
end;

function TPSStackHelper.TArrayEnumerator.HasNext: Boolean;
begin
  Result := I < N;
end;

function TPSStackHelper.TArrayEnumerator.Next: String;
begin
  Result := VNGetString(PSGetArrayField(Arr, I));
  Inc(I);
end;

procedure TPSStackHelper.SetArray(const ItemNo: Longint; const Data: TArray<String>; const FieldNo: Longint);
begin
  var N := System.Length(Data);
  var Arr := SetArray(ItemNo, FieldNo, N);
  for var I := 0 to N-1 do
    VNSetString(PSGetArrayField(Arr, I), Data[I]);
end;

procedure TPSStackHelper.SetArray(const ItemNo: Longint; const Data: TStrings; const FieldNo: Longint);
begin
  var N := Data.Count;
  var Arr := SetArray(ItemNo, FieldNo, N);
  for var I := 0 to N-1 do
    VNSetString(PSGetArrayField(Arr, I), Data[I]);
end;

procedure TPSStackHelper.SetInt(const ItemNo: Longint; const Data: Integer;
  const FieldNo: Longint);
begin
  if FieldNo = -1 then
    inherited SetInt(ItemNo, Data)
  else begin
    var PSVariantIFC := NewTPSVariantRecordIFC(Items[ItemNo], FieldNo);
    VNSetInt(PSVariantIFC, Data);
  end;
end;

{---}

function ScriptDlgProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'PAGEFROMID' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetClass(PStart, GetWizardForm.PageFromID(Stack.GetInt(PStart-1)));
  end else if Proc.Name = 'PAGEINDEXFROMID' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetInt(PStart, GetWizardForm.PageIndexFromID(Stack.GetInt(PStart-1)));
  end else if Proc.Name = 'CREATECUSTOMPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewPage := TWizardPage.Create(GetWizardForm);
    try
      NewPage.Caption := Stack.GetString(PStart-2);
      NewPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewPage, Stack.GetInt(PStart-1));
    except
      NewPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewPage);
  end else if Proc.Name = 'CREATEINPUTQUERYPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewInputQueryPage := TInputQueryWizardPage.Create(GetWizardForm);
    try
      NewInputQueryPage.Caption := Stack.GetString(PStart-2);
      NewInputQueryPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewInputQueryPage, Stack.GetInt(PStart-1));
      NewInputQueryPage.Initialize(Stack.GetString(PStart-4));
    except
      NewInputQueryPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewInputQueryPage);
  end else if Proc.Name = 'CREATEINPUTOPTIONPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewInputOptionPage := TInputOptionWizardPage.Create(GetWizardForm);
    try
      NewInputOptionPage.Caption := Stack.GetString(PStart-2);
      NewInputOptionPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewInputOptionPage, Stack.GetInt(PStart-1));
      NewInputOptionPage.Initialize(Stack.GetString(PStart-4),
        Stack.GetBool(PStart-5), Stack.GetBool(PStart-6));
    except
      NewInputOptionPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewInputOptionPage);
  end else if Proc.Name = 'CREATEINPUTDIRPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewInputDirPage := TInputDirWizardPage.Create(GetWizardForm);
    try
      NewInputDirPage.Caption := Stack.GetString(PStart-2);
      NewInputDirPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewInputDirPage, Stack.GetInt(PStart-1));
      NewInputDirPage.Initialize(Stack.GetString(PStart-4), Stack.GetBool(PStart-5),
         Stack.GetString(PStart-6));
    except
      NewInputDirPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewInputDirPage);
  end else if Proc.Name = 'CREATEINPUTFILEPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewInputFilePage := TInputFileWizardPage.Create(GetWizardForm);
    try
      NewInputFilePage.Caption := Stack.GetString(PStart-2);
      NewInputFilePage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewInputFilePage, Stack.GetInt(PStart-1));
      NewInputFilePage.Initialize(Stack.GetString(PStart-4));
    except
      NewInputFilePage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewInputFilePage);
  end else if Proc.Name = 'CREATEOUTPUTMSGPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewOutputMsgPage := TOutputMsgWizardPage.Create(GetWizardForm);
    try
      NewOutputMsgPage.Caption := Stack.GetString(PStart-2);
      NewOutputMsgPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewOutputMsgPage, Stack.GetInt(PStart-1));
      NewOutputMsgPage.Initialize(Stack.GetString(PStart-4));
    except
      NewOutputMsgPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewOutputMsgPage);
  end else if Proc.Name = 'CREATEOUTPUTMSGMEMOPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewOutputMsgMemoPage := TOutputMsgMemoWizardPage.Create(GetWizardForm);
    try
      NewOutputMsgMemoPage.Caption := Stack.GetString(PStart-2);
      NewOutputMsgMemoPage.Description := Stack.GetString(PStart-3);
      GetWizardForm.AddPage(NewOutputMsgMemoPage, Stack.GetInt(PStart-1));
      NewOutputMsgMemoPage.Initialize(Stack.GetString(PStart-4),
         Stack.GetAnsiString(PStart-5));
    except
      NewOutputMsgMemoPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewOutputMsgMemoPage);
  end else if Proc.Name = 'CREATEOUTPUTPROGRESSPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewOutputProgressPage := TOutputProgressWizardPage.Create(GetWizardForm);
    try
      NewOutputProgressPage.Caption := Stack.GetString(PStart-1);
      NewOutputProgressPage.Description := Stack.GetString(PStart-2);
      GetWizardForm.AddPage(NewOutputProgressPage, -1);
      NewOutputProgressPage.Initialize;
    except
      NewOutputProgressPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewOutputProgressPage);
  end else if Proc.Name = 'CREATEOUTPUTMARQUEEPROGRESSPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewOutputMarqueeProgressPage := TOutputMarqueeProgressWizardPage.Create(GetWizardForm);
    try
      NewOutputMarqueeProgressPage.Caption := Stack.GetString(PStart-1);
      NewOutputMarqueeProgressPage.Description := Stack.GetString(PStart-2);
      GetWizardForm.AddPage(NewOutputMarqueeProgressPage, -1);
      NewOutputMarqueeProgressPage.Initialize;
    except
      NewOutputMarqueeProgressPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewOutputMarqueeProgressPage);
  end else if Proc.Name = 'CREATEDOWNLOADPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewDownloadPage := TDownloadWizardPage.Create(GetWizardForm);
    try
      NewDownloadPage.Caption := Stack.GetString(PStart-1);
      NewDownloadPage.Description := Stack.GetString(PStart-2);
      GetWizardForm.AddPage(NewDownloadPage, -1);
      NewDownloadPage.Initialize;
      NewDownloadPage.OnDownloadProgress := TOnDownloadProgress(Stack.GetProc(PStart-3, Caller));
    except
      NewDownloadPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewDownloadPage);
  end else if Proc.Name = 'CREATEEXTRACTIONPAGE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    var NewExtractionPage := TExtractionWizardPage.Create(GetWizardForm);
    try
      NewExtractionPage.Caption := Stack.GetString(PStart-1);
      NewExtractionPage.Description := Stack.GetString(PStart-2);
      GetWizardForm.AddPage(NewExtractionPage, -1);
      NewExtractionPage.Initialize;
      NewExtractionPage.OnExtractionProgress := TOnExtractionProgress(Stack.GetProc(PStart-3, Caller));
    except
      NewExtractionPage.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewExtractionPage);
  end else if Proc.Name = 'SCALEX' then begin
    InitializeScaleBaseUnits;
    Stack.SetInt(PStart, MulDiv(Stack.GetInt(PStart-1), ScaleBaseUnitX, OrigBaseUnitX));
  end else if Proc.Name = 'SCALEY' then begin
    InitializeScaleBaseUnits;
    Stack.SetInt(PStart, MulDiv(Stack.GetInt(PStart-1), ScaleBaseUnitY, OrigBaseUnitY));
  end else if Proc.Name = 'CREATECUSTOMFORM' then begin
    var NewSetupForm := TSetupForm.CreateNew(nil);
    try
      NewSetupForm.AutoScroll := False;
      NewSetupForm.BorderStyle := bsDialog;
      NewSetupForm.InitializeFont;
    except
      NewSetupForm.Free;
      raise;
    end;
    Stack.SetClass(PStart, NewSetupForm);
  end else
    Result := False;
end;

function NewDiskFormProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
  S: String;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'SELECTDISK' then begin
    S := Stack.GetString(PStart-3);
    Stack.SetBool(PStart, SelectDisk(Stack.GetInt(PStart-1), Stack.GetString(PStart-2), S));
    Stack.SetString(PStart-3, S);
  end else
    Result := False;
end;

function BrowseFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
  S: String;
  ParentWnd: HWND;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'BROWSEFORFOLDER' then begin
    if Assigned(WizardForm) then
      ParentWnd := WizardForm.Handle
    else
      ParentWnd := 0;
    S := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, BrowseForFolder(Stack.GetString(PStart-1), S, ParentWnd, Stack.GetBool(PStart-3)));
    Stack.SetString(PStart-2, S);
  end else if Proc.Name = 'GETOPENFILENAME' then begin
    if Assigned(WizardForm) then
      ParentWnd := WizardForm.Handle
    else
      ParentWnd := 0;
    S := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, NewGetOpenFileName(Stack.GetString(PStart-1), S, Stack.GetString(PStart-3), Stack.GetString(PStart-4), Stack.GetString(PStart-5), ParentWnd));
    Stack.SetString(PStart-2, S);
  end else if Proc.Name = 'GETOPENFILENAMEMULTI' then begin
    if Assigned(WizardForm) then
      ParentWnd := WizardForm.Handle
    else
      ParentWnd := 0;
    Stack.SetBool(PStart, NewGetOpenFileNameMulti(Stack.GetString(PStart-1), TStrings(Stack.GetClass(PStart-2)), Stack.GetString(PStart-3), Stack.GetString(PStart-4), Stack.GetString(PStart-5), ParentWnd));
  end else if Proc.Name = 'GETSAVEFILENAME' then begin
    if Assigned(WizardForm) then
      ParentWnd := WizardForm.Handle
    else
      ParentWnd := 0;
    S := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, NewGetSaveFileName(Stack.GetString(PStart-1), S, Stack.GetString(PStart-3), Stack.GetString(PStart-4), Stack.GetString(PStart-5), ParentWnd));
    Stack.SetString(PStart-2, S);
  end else
    Result := False;
end;

function CommonFuncVclProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'MINIMIZEPATHNAME' then begin
    Stack.SetString(PStart, MinimizePathName(Stack.GetString(PStart-1), TFont(Stack.GetClass(PStart-2)), Stack.GetInt(PStart-3)));
  end else
    Result := False;
end;

function CommonFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;

  procedure CrackCodeRootKey(CodeRootKey: HKEY; var RegView: TRegView;
    var RootKey: HKEY);
  begin
    if (CodeRootKey and not CodeRootKeyValidFlags) = HKEY_AUTO then begin
      { Change HKA to HKLM or HKCU, keeping our special flag bits. }
      CodeRootKey := (CodeRootKey and CodeRootKeyValidFlags) or InstallModeRootKey;
    end else begin
      { Allow only predefined key handles (8xxxxxxx). Can't accept handles to
        open keys because they might have our special flag bits set.
        Also reject unknown flags which may have a meaning in the future. }
      if (CodeRootKey shr 31 <> 1) or
         ((CodeRootKey and CodeRootKeyFlagMask) and not CodeRootKeyValidFlags <> 0) then
        InternalError('Invalid RootKey value');
    end;
    
    if CodeRootKey and CodeRootKeyFlag32Bit <> 0 then
      RegView := rv32Bit
    else if CodeRootKey and CodeRootKeyFlag64Bit <> 0 then begin
      if not IsWin64 then
        InternalError('Cannot access 64-bit registry keys on this version of Windows');
      RegView := rv64Bit;
    end
    else
      RegView := InstallDefaultRegView;
    RootKey := CodeRootKey and not CodeRootKeyFlagMask;
  end;

  function GetSubkeyOrValueNames(const RegView: TRegView; const RootKey: HKEY;
    const SubKeyName: String; const Stack: TPSStack; const ItemNo: Longint; const Subkey: Boolean): Boolean;
  const
    samDesired: array [Boolean] of REGSAM = (KEY_QUERY_VALUE, KEY_ENUMERATE_SUB_KEYS);
  var
    K: HKEY;
    Buf, S: String;
    BufSize, R: DWORD;
  begin
    Result := False;
    SetString(Buf, nil, 512);
    if RegOpenKeyExView(RegView, RootKey, PChar(SubKeyName), 0, samDesired[Subkey], K) <> ERROR_SUCCESS then
      Exit;
    try
      var ArrayBuilder := Stack.InitArrayBuilder(ItemNo);
      while True do begin
        BufSize := Length(Buf);
        if Subkey then
          R := RegEnumKeyEx(K, ArrayBuilder.I, @Buf[1], BufSize, nil, nil, nil, nil)
        else
          R := RegEnumValue(K, ArrayBuilder.I, @Buf[1], BufSize, nil, nil, nil, nil);
        case R of
          ERROR_SUCCESS: ;
          ERROR_NO_MORE_ITEMS: Break;
          ERROR_MORE_DATA:
            begin
              { Double the size of the buffer and try again }
              if Length(Buf) >= 65536 then begin
                { Sanity check: If we tried a 64 KB buffer and it's still saying
                  there's more data, something must be seriously wrong. Bail. }
                Exit;
              end;
              SetString(Buf, nil, Length(Buf) * 2);
              Continue;
            end;
        else
          Exit;  { unknown failure... }
        end;
        SetString(S, PChar(@Buf[1]), BufSize);
        ArrayBuilder.Add(S);
      end;
    finally
      RegCloseKey(K);
    end;
    Result := True;
  end;

var
  PStart: Cardinal;
  ExistingFilename: String;
  RegView: TRegView;
  K, RootKey: HKEY;
  S, N, V: String;
  DataS: AnsiString;
  Typ, ExistingTyp, Data, Size: DWORD;
  I: Integer;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'FILEEXISTS' then begin
    Stack.SetBool(PStart, NewFileExistsRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'DIREXISTS' then begin
    Stack.SetBool(PStart, DirExistsRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'FILEORDIREXISTS' then begin
    Stack.SetBool(PStart, FileOrDirExistsRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETINISTRING' then begin
    Stack.SetString(PStart, GetIniString(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetString(PStart-3), Stack.GetString(PStart-4)));
  end else if Proc.Name = 'GETINIINT' then begin
    Stack.SetInt(PStart, GetIniInt(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetInt(PStart-3), Stack.GetInt(PStart-4), Stack.GetInt(PStart-5), Stack.GetString(PStart-6)));
  end else if Proc.Name = 'GETINIBOOL' then begin
    Stack.SetBool(PStart, GetIniBool(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetBool(PStart-3), Stack.GetString(PStart-4)));
  end else if Proc.Name = 'INIKEYEXISTS' then begin
    Stack.SetBool(PStart, IniKeyExists(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetString(PStart-3)));
  end else if Proc.Name = 'ISINISECTIONEMPTY' then begin
    Stack.SetBool(PStart, IsIniSectionEmpty(Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'SETINISTRING' then begin
    Stack.SetBool(PStart, SetIniString(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetString(PStart-3), Stack.GetString(PStart-4)));
  end else if Proc.Name = 'SETINIINT' then begin
    Stack.SetBool(PStart, SetIniInt(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetInt(PStart-3), Stack.GetString(PStart-4)));
  end else if Proc.Name = 'SETINIBOOL' then begin
    Stack.SetBool(PStart, SetIniBool(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetBool(PStart-3), Stack.GetString(PStart-4)));
  end else if Proc.Name = 'DELETEINIENTRY' then begin
    DeleteIniEntry(Stack.GetString(PStart), Stack.GetString(PStart-1), Stack.GetString(PStart-2));
  end else if Proc.Name = 'DELETEINISECTION' then begin
    DeleteIniSection(Stack.GetString(PStart), Stack.GetString(PStart-1));
  end else if Proc.Name = 'GETENV' then begin
    Stack.SetString(PStart, GetEnv(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETCMDTAIL' then begin
    Stack.SetString(PStart, GetCmdTail());
  end else if Proc.Name = 'PARAMCOUNT' then begin
    if NewParamsForCode.Count = 0 then
      InternalError('NewParamsForCode not set');
    Stack.SetInt(PStart, NewParamsForCode.Count-1);
  end else if Proc.Name = 'PARAMSTR' then begin
    I := Stack.GetInt(PStart-1);
    if (I >= 0) and (I < NewParamsForCode.Count) then
      Stack.SetString(PStart, NewParamsForCode[I])
    else
      Stack.SetString(PStart, '');
  end else if Proc.Name = 'ADDBACKSLASH' then begin
    Stack.SetString(PStart, AddBackslash(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'REMOVEBACKSLASH' then begin
    Stack.SetString(PStart, RemoveBackslash(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'REMOVEBACKSLASHUNLESSROOT' then begin
    Stack.SetString(PStart, RemoveBackslashUnlessRoot(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'ADDQUOTES' then begin
    Stack.SetString(PStart, AddQuotes(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'REMOVEQUOTES' then begin
    Stack.SetString(PStart, RemoveQuotes(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETSHORTNAME' then begin
    Stack.SetString(PStart, GetShortNameRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETWINDIR' then begin
    Stack.SetString(PStart, GetWinDir());
  end else if Proc.Name = 'GETSYSTEMDIR' then begin
    Stack.SetString(PStart, GetSystemDir());
  end else if Proc.Name = 'GETSYSWOW64DIR' then begin
    Stack.SetString(PStart, GetSysWow64Dir());
  end else if Proc.Name = 'GETSYSNATIVEDIR' then begin
    Stack.SetString(PStart, GetSysNativeDir(IsWin64));
  end else if Proc.Name = 'GETTEMPDIR' then begin
    Stack.SetString(PStart, GetTempDir());
  end else if Proc.Name = 'STRINGCHANGE' then begin
    S := Stack.GetString(PStart-1);
    Stack.SetInt(PStart, StringChange(S, Stack.GetString(PStart-2), Stack.GetString(PStart-3)));
    Stack.SetString(PStart-1, S);
  end else if Proc.Name = 'STRINGCHANGEEX' then begin
    S := Stack.GetString(PStart-1);
    Stack.SetInt(PStart, StringChangeEx(S, Stack.GetString(PStart-2), Stack.GetString(PStart-3), Stack.GetBool(PStart-4)));
    Stack.SetString(PStart-1, S);
  end else if Proc.Name = 'USINGWINNT' then begin
    Stack.SetBool(PStart, True);
  end else if (Proc.Name = 'COPYFILE') or (Proc.Name = 'FILECOPY') then begin
    ExistingFilename := Stack.GetString(PStart-1);
    if not IsProtectedSrcExe(ExistingFilename) then
      Stack.SetBool(PStart, CopyFileRedir(ScriptFuncDisableFsRedir,
        ExistingFilename, Stack.GetString(PStart-2), Stack.GetBool(PStart-3)))
    else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'CONVERTPERCENTSTR' then begin
    S := Stack.GetString(PStart-1);
    Stack.SetBool(PStart, ConvertPercentStr(S));
    Stack.SetString(PStart-1, S);
  end else if Proc.Name = 'REGKEYEXISTS' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      Stack.SetBool(PStart, True);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGVALUEEXISTS' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      Stack.SetBool(PStart, RegValueExists(K, PChar(N)));
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGDELETEKEYINCLUDINGSUBKEYS' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, RegDeleteKeyIncludingSubkeys(RegView, RootKey, PChar(S)) = ERROR_SUCCESS);
  end else if Proc.Name = 'REGDELETEKEYIFEMPTY' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, RegDeleteKeyIfEmpty(RegView, RootKey, PChar(S)) = ERROR_SUCCESS);
  end else if Proc.Name = 'REGDELETEVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_SET_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      Stack.SetBool(PStart, RegDeleteValue(K, PChar(N)) = ERROR_SUCCESS);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGGETSUBKEYNAMES' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    Stack.SetBool(PStart, GetSubkeyOrValueNames(RegView, RootKey,
      Stack.GetString(PStart-2), Stack, PStart-3, True));
  end else if Proc.Name = 'REGGETVALUENAMES' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    Stack.SetBool(PStart, GetSubkeyOrValueNames(RegView, RootKey,
      Stack.GetString(PStart-2), Stack, PStart-3, False));
  end else if Proc.Name = 'REGQUERYSTRINGVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      S := Stack.GetString(PStart-4);
      Stack.SetBool(PStart, RegQueryStringValue(K, PChar(N), S));
      Stack.SetString(PStart-4, S);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGQUERYMULTISTRINGVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      S := Stack.GetString(PStart-4);
      Stack.SetBool(PStart, RegQueryMultiStringValue(K, PChar(N), S));
      Stack.SetString(PStart-4, S);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGQUERYDWORDVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      Size := SizeOf(Data);
      if (RegQueryValueEx(K, PChar(N), nil, @Typ, @Data, @Size) = ERROR_SUCCESS) and (Typ = REG_DWORD) then begin
        Stack.SetInt(PStart-4, Data);
        Stack.SetBool(PStart, True);
      end else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGQUERYBINARYVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegOpenKeyExView(RegView, RootKey, PChar(S), 0, KEY_QUERY_VALUE, K) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      if RegQueryValueEx(K, PChar(N), nil, @Typ, nil, @Size) = ERROR_SUCCESS then begin
        SetLength(DataS, Size);
        if RegQueryValueEx(K, PChar(N), nil, @Typ, @DataS[1], @Size) = ERROR_SUCCESS then begin
          Stack.SetAnsiString(PStart-4, DataS);
          Stack.SetBool(PStart, True);
        end else
          Stack.SetBool(PStart, False);
      end else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGWRITESTRINGVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegCreateKeyExView(RegView, RootKey, PChar(S), 0, nil, REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE or KEY_SET_VALUE, nil, K, nil) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      V := Stack.GetString(PStart-4);
      if (RegQueryValueEx(K, PChar(N), nil, @ExistingTyp, nil, nil) = ERROR_SUCCESS) and (ExistingTyp = REG_EXPAND_SZ) then
        Typ := REG_EXPAND_SZ
      else
        Typ := REG_SZ;
      if RegSetValueEx(K, PChar(N), 0, Typ, PChar(V), (Length(V)+1)*SizeOf(V[1])) = ERROR_SUCCESS then
        Stack.SetBool(PStart, True)
      else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGWRITEEXPANDSTRINGVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegCreateKeyExView(RegView, RootKey, PChar(S), 0, nil, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nil, K, nil) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      V := Stack.GetString(PStart-4);
      if RegSetValueEx(K, PChar(N), 0, REG_EXPAND_SZ, PChar(V), (Length(V)+1)*SizeOf(V[1])) = ERROR_SUCCESS then
        Stack.SetBool(PStart, True)
      else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGWRITEMULTISTRINGVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegCreateKeyExView(RegView, RootKey, PChar(S), 0, nil, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nil, K, nil) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      V := Stack.GetString(PStart-4);
      { Multi-string data requires two null terminators: one after the last
        string, and one to mark the end.
        Delphi's String type is implicitly null-terminated, so only one null
        needs to be added to the end. }
      if (V <> '') and (V[Length(V)] <> #0) then
        V := V + #0;
      if RegSetValueEx(K, PChar(N), 0, REG_MULTI_SZ, PChar(V), (Length(V)+1)*SizeOf(V[1])) = ERROR_SUCCESS then
        Stack.SetBool(PStart, True)
      else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGWRITEDWORDVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegCreateKeyExView(RegView, RootKey, PChar(S), 0, nil, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nil, K, nil) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      Data := Stack.GetInt(PStart-4);
      if RegSetValueEx(K, PChar(N), 0, REG_DWORD, @Data, SizeOf(Data)) = ERROR_SUCCESS then
        Stack.SetBool(PStart, True)
      else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'REGWRITEBINARYVALUE' then begin
    CrackCodeRootKey(Stack.GetInt(PStart-1), RegView, RootKey);
    S := Stack.GetString(PStart-2);
    if RegCreateKeyExView(RegView, RootKey, PChar(S), 0, nil, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nil, K, nil) = ERROR_SUCCESS then begin
      N := Stack.GetString(PStart-3);
      DataS := Stack.GetAnsiString(PStart-4);
      if RegSetValueEx(K, PChar(N), 0, REG_BINARY, @DataS[1], Length(DataS)) = ERROR_SUCCESS then
        Stack.SetBool(PStart, True)
      else
        Stack.SetBool(PStart, False);
      RegCloseKey(K);
    end else
      Stack.SetBool(PStart, False);
  end else if (Proc.Name = 'ISADMIN') or (Proc.Name = 'ISADMINLOGGEDON') then begin
    Stack.SetBool(PStart, IsAdmin);
  end else if Proc.Name = 'ISPOWERUSERLOGGEDON' then begin
    Stack.SetBool(PStart, IsPowerUserLoggedOn());
  end else if Proc.Name= 'ISADMININSTALLMODE' then begin
    Stack.SetBool(PStart, IsAdminInstallMode);
  end else if Proc.Name = 'FONTEXISTS' then begin
    Stack.SetBool(PStart, FontExists(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETUILANGUAGE' then begin
    Stack.SetInt(PStart, GetUILanguage);
  end else if Proc.Name = 'ADDPERIOD' then begin
    Stack.SetString(PStart, AddPeriod(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'CHARLENGTH' then begin
    Stack.SetInt(PStart, PathCharLength(Stack.GetString(PStart-1), Stack.GetInt(PStart-2)));
  end else if Proc.Name = 'SETNTFSCOMPRESSION' then begin
    Stack.SetBool(PStart, SetNTFSCompressionRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), Stack.GetBool(PStart-2)));
  end else if Proc.Name = 'ISWILDCARD' then begin
    Stack.SetBool(PStart, IsWildcard(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'WILDCARDMATCH' then begin
    S := Stack.GetString(PStart-1);
    N := Stack.GetString(PStart-2);
    Stack.SetBool(PStart, WildcardMatch(PChar(S), PChar(N)));
  end else
    Result := False;
end;

function InstallProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  if IsUninstaller then
    NoUninstallFuncError(Proc.Name);

  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'EXTRACTTEMPORARYFILE' then begin
    ExtractTemporaryFile(Stack.GetString(PStart));
  end else if Proc.Name = 'EXTRACTTEMPORARYFILES' then begin
    Stack.SetInt(PStart, ExtractTemporaryFiles(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'DOWNLOADTEMPORARYFILE' then begin
    Stack.SetInt64(PStart, DownloadTemporaryFile(Stack.GetString(PStart-1), Stack.GetString(PStart-2), Stack.GetString(PStart-3), TOnDownloadProgress(Stack.GetProc(PStart-4, Caller))));
  end else if Proc.Name = 'SETDOWNLOADCREDENTIALS' then begin
    SetDownloadCredentials(Stack.GetString(PStart),Stack.GetString(PStart-1));
  end else if Proc.Name = 'DOWNLOADTEMPORARYFILESIZE' then begin
    Stack.SetInt64(PStart, DownloadTemporaryFileSize(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'DOWNLOADTEMPORARYFILEDATE' then begin
    Stack.SetString(PStart, DownloadTemporaryFileDate(Stack.GetString(PStart-1)));
  end else
    Result := False;
end;

{ InstFunc }
procedure ProcessMessagesProc; far;
begin
  Application.ProcessMessages;
end;

procedure ExecAndLogOutputLog(const S: String; const Error, FirstLine: Boolean; const Data: NativeInt);
begin
  Log(S);
end;

type
  { These must keep this in synch with Compiler.ScriptFunc.pas }
  TOnLog = procedure(const S: String; const Error, FirstLine: Boolean) of object;

procedure ExecAndLogOutputLogCustom(const S: String; const Error, FirstLine: Boolean; const Data: NativeInt);
begin
  var OnLog := TOnLog(PMethod(Data)^);
  OnLog(S, Error, FirstLine);
end;

function InstFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;

  function GetMD5OfFile(const DisableFsRedir: Boolean; const Filename: String): TMD5Digest;
  { Gets MD5 sum of the file Filename. An exception will be raised upon
    failure. }
  var
    Buf: array[0..65535] of Byte;
  begin
    var Context: TMD5Context;
    MD5Init(Context);
    var F := TFileRedir.Create(DisableFsRedir, Filename, fdOpenExisting, faRead, fsReadWrite);
    try
      while True do begin
        var NumRead := F.Read(Buf, SizeOf(Buf));
        if NumRead = 0 then
          Break;
        MD5Update(Context, Buf, NumRead);
      end;
    finally
      F.Free;
    end;
    Result := MD5Final(Context);
  end;

  function GetSHA1OfFile(const DisableFsRedir: Boolean; const Filename: String): TSHA1Digest;
  { Gets SHA-1 sum of the file Filename. An exception will be raised upon
    failure. }
  var
    Buf: array[0..65535] of Byte;
  begin
    var Context: TSHA1Context;
    SHA1Init(Context);
    var F := TFileRedir.Create(DisableFsRedir, Filename, fdOpenExisting, faRead, fsReadWrite);
    try
      while True do begin
        var NumRead := F.Read(Buf, SizeOf(Buf));
        if NumRead = 0 then
          Break;
        SHA1Update(Context, Buf, NumRead);
      end;
    finally
      F.Free;
    end;
    Result := SHA1Final(Context);
  end;

  function GetMD5OfAnsiString(const S: AnsiString): TMD5Digest;
  begin
    Result := MD5Buf(Pointer(S)^, Length(S)*SizeOf(S[1]));
  end;

  function GetMD5OfUnicodeString(const S: UnicodeString): TMD5Digest;
  begin
    Result := MD5Buf(Pointer(S)^, Length(S)*SizeOf(S[1]));
  end;

  function GetSHA1OfAnsiString(const S: AnsiString): TSHA1Digest;
  begin
    Result := SHA1Buf(Pointer(S)^, Length(S)*SizeOf(S[1]));
  end;

  function GetSHA1OfUnicodeString(const S: UnicodeString): TSHA1Digest;
  begin
    Result := SHA1Buf(Pointer(S)^, Length(S)*SizeOf(S[1]));
end;

var
  PStart: Cardinal;
  Filename: String;
  WindowDisabler: TWindowDisabler;
  ResultCode, ErrorCode: Integer;
  FreeBytes, TotalBytes: Integer64;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'CHECKFORMUTEXES' then begin
    Stack.SetBool(PStart, CheckForMutexes(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'DECREMENTSHAREDCOUNT' then begin
    if Stack.GetBool(PStart-1) then begin
      if not IsWin64 then
        InternalError('Cannot access 64-bit registry keys on this version of Windows');
      Stack.SetBool(PStart, DecrementSharedCount(rv64Bit, Stack.GetString(PStart-2)));
    end
    else
      Stack.SetBool(PStart, DecrementSharedCount(rv32Bit, Stack.GetString(PStart-2)));
  end else if Proc.Name = 'DELAYDELETEFILE' then begin
    DelayDeleteFile(ScriptFuncDisableFsRedir, Stack.GetString(PStart), Stack.GetInt(PStart-1), 250, 250);
  end else if Proc.Name = 'DELTREE' then begin
    Stack.SetBool(PStart, DelTree(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), Stack.GetBool(PStart-2), Stack.GetBool(PStart-3), Stack.GetBool(PStart-4), False, nil, nil, nil));
  end else if Proc.Name = 'GENERATEUNIQUENAME' then begin
    Stack.SetString(PStart, GenerateUniqueName(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'GETCOMPUTERNAMESTRING' then begin
    Stack.SetString(PStart, GetComputerNameString());
  end else if Proc.Name = 'GETMD5OFFILE' then begin
    Stack.SetString(PStart, MD5DigestToString(GetMD5OfFile(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETMD5OFSTRING' then begin
    Stack.SetString(PStart, MD5DigestToString(GetMD5OfAnsiString(Stack.GetAnsiString(PStart-1))));
  end else if Proc.Name = 'GETMD5OFUNICODESTRING' then begin
    Stack.SetString(PStart, MD5DigestToString(GetMD5OfUnicodeString(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETSHA1OFFILE' then begin
    Stack.SetString(PStart, SHA1DigestToString(GetSHA1OfFile(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETSHA1OFSTRING' then begin
    Stack.SetString(PStart, SHA1DigestToString(GetSHA1OfAnsiString(Stack.GetAnsiString(PStart-1))));
  end else if Proc.Name = 'GETSHA1OFUNICODESTRING' then begin
    Stack.SetString(PStart, SHA1DigestToString(GetSHA1OfUnicodeString(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETSHA256OFFILE' then begin
    Stack.SetString(PStart, SHA256DigestToString(GetSHA256OfFile(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETSHA256OFSTRING' then begin
    Stack.SetString(PStart, SHA256DigestToString(GetSHA256OfAnsiString(Stack.GetAnsiString(PStart-1))));
  end else if Proc.Name = 'GETSHA256OFUNICODESTRING' then begin
    Stack.SetString(PStart, SHA256DigestToString(GetSHA256OfUnicodeString(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'GETSPACEONDISK' then begin
    if GetSpaceOnDisk(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), FreeBytes, TotalBytes) then begin
      if Stack.GetBool(PStart-2) then begin
        Div64(FreeBytes, 1024*1024);
        Div64(TotalBytes, 1024*1024);
      end;
      { Cap at 2 GB, as [Code] doesn't support 64-bit integers }
      if (FreeBytes.Hi <> 0) or (FreeBytes.Lo and $80000000 <> 0) then
        FreeBytes.Lo := $7FFFFFFF;
      if (TotalBytes.Hi <> 0) or (TotalBytes.Lo and $80000000 <> 0) then
        TotalBytes.Lo := $7FFFFFFF;
      Stack.SetUInt(PStart-3, FreeBytes.Lo);
      Stack.SetUInt(PStart-4, TotalBytes.Lo);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'GETSPACEONDISK64' then begin
    if GetSpaceOnDisk(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), FreeBytes, TotalBytes) then begin
      Stack.SetInt64(PStart-2, Int64(FreeBytes.Hi) shl 32 + FreeBytes.Lo);
      Stack.SetInt64(PStart-3, Int64(TotalBytes.Hi) shl 32 + TotalBytes.Lo);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'GETUSERNAMESTRING' then begin
    Stack.SetString(PStart, GetUserNameString());
  end else if Proc.Name = 'INCREMENTSHAREDCOUNT' then begin
    if Stack.GetBool(PStart) then begin
      if not IsWin64 then
        InternalError('Cannot access 64-bit registry keys on this version of Windows');
      IncrementSharedCount(rv64Bit, Stack.GetString(PStart-1), Stack.GetBool(PStart-2));
    end
    else
      IncrementSharedCount(rv32Bit, Stack.GetString(PStart-1), Stack.GetBool(PStart-2));
  end else if (Proc.Name = 'EXEC') or (Proc.Name = 'EXECASORIGINALUSER') or
              (Proc.Name = 'EXECANDLOGOUTPUT') or (Proc.Name = 'EXECANDCAPTUREOUTPUT') then begin
    var RunAsOriginalUser := Proc.Name = 'EXECASORIGINALUSER';
    var Method: TMethod; { Must stay alive until OutputReader is freed }
    var OutputReader: TCreateProcessOutputReader := nil;
    try
      if Proc.Name = 'EXECANDLOGOUTPUT' then begin
        Method := Stack.GetProc(PStart-7, Caller);
        if Method.Code <> nil then
          OutputReader := TCreateProcessOutputReader.Create(ExecAndLogOutputLogCustom, NativeInt(@Method))
        else if GetLogActive then
          OutputReader := TCreateProcessOutputReader.Create(ExecAndLogOutputLog, 0);
      end else if Proc.Name = 'EXECANDCAPTUREOUTPUT' then
        OutputReader := TCreateProcessOutputReader.Create(ExecAndLogOutputLog, 0, omCapture);
      var ExecWait := TExecWait(Stack.GetInt(PStart-5));
      if IsUninstaller and RunAsOriginalUser then
        NoUninstallFuncError(Proc.Name)
      else if (OutputReader <> nil) and (ExecWait <> ewWaitUntilTerminated) then
        InternalError(Format('Must call "%s" function with Wait = ewWaitUntilTerminated', [Proc.Name]));

      Filename := Stack.GetString(PStart-1);
      if not IsProtectedSrcExe(Filename) then begin
        { Disable windows so the user can't utilize our UI during the InstExec
          call }
        WindowDisabler := TWindowDisabler.Create;
        try
          Stack.SetBool(PStart, InstExecEx(RunAsOriginalUser,
            ScriptFuncDisableFsRedir, Filename, Stack.GetString(PStart-2),
            Stack.GetString(PStart-3), ExecWait,
            Stack.GetInt(PStart-4), ProcessMessagesProc, OutputReader, ResultCode));
        finally
          WindowDisabler.Free;
        end;
        Stack.SetInt(PStart-6, ResultCode);
        if Proc.Name = 'EXECANDCAPTUREOUTPUT' then begin
          { Set the three TExecOutput fields }
          Stack.SetArray(PStart-7, OutputReader.CaptureOutList, 0);
          Stack.SetArray(PStart-7, OutputReader.CaptureErrList, 1);
          Stack.SetInt(PStart-7, OutputReader.CaptureError.ToInteger, 2);
        end;
      end else begin
        Stack.SetBool(PStart, False);
        Stack.SetInt(PStart-6, ERROR_ACCESS_DENIED);
      end;
    finally
      OutputReader.Free;
    end;
  end else if (Proc.Name = 'SHELLEXEC') or (Proc.Name = 'SHELLEXECASORIGINALUSER') then begin
    var RunAsOriginalUser := Proc.Name = 'SHELLEXECASORIGINALUSER';
    if IsUninstaller and RunAsOriginalUser then
      NoUninstallFuncError(Proc.Name);

    Filename := Stack.GetString(PStart-2);
    if not IsProtectedSrcExe(Filename) then begin
      { Disable windows so the user can't utilize our UI during the
        InstShellExec call }
      WindowDisabler := TWindowDisabler.Create;
      try
        Stack.SetBool(PStart, InstShellExecEx(RunAsOriginalUser,
          Stack.GetString(PStart-1), Filename, Stack.GetString(PStart-3),
          Stack.GetString(PStart-4), TExecWait(Stack.GetInt(PStart-6)),
          Stack.GetInt(PStart-5), ProcessMessagesProc, ErrorCode));
      finally
        WindowDisabler.Free;
      end;
      Stack.SetInt(PStart-7, ErrorCode);
    end else begin
      Stack.SetBool(PStart, False);
      Stack.SetInt(PStart-7, ERROR_ACCESS_DENIED);
    end;
  end else if Proc.Name = 'ISPROTECTEDSYSTEMFILE' then begin
    Stack.SetBool(PStart, IsProtectedSystemFile(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'MAKEPENDINGFILERENAMEOPERATIONSCHECKSUM' then begin
    Stack.SetString(PStart, SHA256DigestToString(MakePendingFileRenameOperationsChecksum));
  end else if Proc.Name = 'MODIFYPIFFILE' then begin
    Stack.SetBool(PStart, ModifyPifFile(Stack.GetString(PStart-1), Stack.GetBool(PStart-2)));
  end else if Proc.Name = 'REGISTERSERVER' then begin
    RegisterServer(False, Stack.GetBool(PStart), Stack.GetString(PStart-1), Stack.GetBool(PStart-2));
  end else if Proc.Name = 'UNREGISTERSERVER' then begin
    try
      RegisterServer(True, Stack.GetBool(PStart-1), Stack.GetString(PStart-2), Stack.GetBool(PStart-3));
      Stack.SetBool(PStart, True);
    except
      Stack.SetBool(PStart, False);
    end;
  end else if Proc.Name = 'UNREGISTERFONT' then begin
    UnregisterFont(Stack.GetString(PStart), Stack.GetString(PStart-1), Stack.GetBool(PStart-2));
  end else if Proc.Name = 'RESTARTREPLACE' then begin
    RestartReplace(ScriptFuncDisableFsRedir, Stack.GetString(PStart), Stack.GetString(PStart-1));
  end else if Proc.Name = 'FORCEDIRECTORIES' then begin
    Stack.SetBool(PStart, ForceDirectories(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else
    Result := False;
end;

function InstFuncOleProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'CREATESHELLLINK' then begin
    Stack.SetString(PStart, CreateShellLink(Stack.GetString(PStart-1),
      Stack.GetString(PStart-2), Stack.GetString(PStart-3),
      Stack.GetString(PStart-4), Stack.GetString(PStart-5),
      Stack.GetString(PStart-6), Stack.GetInt(PStart-7),
      Stack.GetInt(PStart-8), 0, '', nil, False, False));
  end else if Proc.Name = 'REGISTERTYPELIBRARY' then begin
    if Stack.GetBool(PStart) then
      HelperRegisterTypeLibrary(False, Stack.GetString(PStart-1))
    else
      RegisterTypeLibrary(Stack.GetString(PStart-1));
  end else if Proc.Name = 'UNREGISTERTYPELIBRARY' then begin
    try
      if Stack.GetBool(PStart-1) then
        HelperRegisterTypeLibrary(True, Stack.GetString(PStart-2))
      else
        UnregisterTypeLibrary(Stack.GetString(PStart-2));
      Stack.SetBool(PStart, True);
    except
      Stack.SetBool(PStart, False);
    end;
  end else if Proc.Name = 'UNPINSHELLLINK' then begin
    Stack.SetBool(PStart, UnpinShellLink(Stack.GetString(PStart-1)));
  end else
    Result := False;
end;

function MainFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;

  function CustomMessage(const MsgName: String): String;
  begin
    if not GetCustomMessageValue(MsgName, Result) then
      InternalError(Format('Unknown custom message name "%s"', [MsgName]));
  end;

var
  PStart: Cardinal;
  MinVersion, OnlyBelowVersion: TSetupVersionData;
  StringList: TStringList;
  S: String;
  Components, Suppressible: Boolean;
  Default: Integer;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'ACTIVELANGUAGE' then begin
    Stack.SetString(PStart, ExpandConst('{language}'));
  end else if Proc.Name = 'EXPANDCONSTANT' then begin
    Stack.SetString(PStart, ExpandConst(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXPANDCONSTANTEX' then begin
    Stack.SetString(PStart, ExpandConstEx(Stack.GetString(PStart-1), [Stack.GetString(PStart-2), Stack.GetString(PStart-3)]));
  end else if Proc.Name = 'EXITSETUPMSGBOX' then begin
    Stack.SetBool(PStart, ExitSetupMsgBox());
  end else if Proc.Name = 'GETSHELLFOLDERBYCSIDL' then begin
    Stack.SetString(PStart, GetShellFolderByCSIDL(Stack.GetInt(PStart-1), Stack.GetBool(PStart-2)));
  end else if Proc.Name = 'INSTALLONTHISVERSION' then begin
    if not StrToSetupVersionData(Stack.GetString(PStart-1), MinVersion) then
      InternalError('InstallOnThisVersion: Invalid MinVersion string')
    else if not StrToSetupVersionData(Stack.GetString(PStart-2), OnlyBelowVersion) then
      InternalError('InstallOnThisVersion: Invalid OnlyBelowVersion string')
    else
      Stack.SetBool(PStart, (InstallOnThisVersion(MinVersion, OnlyBelowVersion) = irInstall));
  end else if Proc.Name = 'GETWINDOWSVERSION' then begin
    Stack.SetUInt(PStart, WindowsVersion);
  end else if Proc.Name = 'GETWINDOWSVERSIONSTRING' then begin
    Stack.SetString(PStart, Format('%u.%.2u.%u', [WindowsVersion shr 24,
      (WindowsVersion shr 16) and $FF, WindowsVersion and $FFFF]));
  end else if (Proc.Name = 'MSGBOX') or (Proc.Name = 'SUPPRESSIBLEMSGBOX') then begin
    if Proc.Name = 'MSGBOX' then begin
      Suppressible := False;
      Default := 0;
    end else begin
      Suppressible := True;
      Default := Stack.GetInt(PStart-4);
    end;
    Stack.SetInt(PStart, LoggedMsgBox(Stack.GetString(PStart-1), GetMsgBoxCaption, TMsgBoxType(Stack.GetInt(PStart-2)), Stack.GetInt(PStart-3), Suppressible, Default));
  end else if (Proc.Name = 'TASKDIALOGMSGBOX') or (Proc.Name = 'SUPPRESSIBLETASKDIALOGMSGBOX') then begin
    if Proc.Name = 'TASKDIALOGMSGBOX' then begin
      Suppressible := False;
      Default := 0;
    end else begin
      Suppressible := True;
      Default := Stack.GetInt(PStart-7);
    end;
    var ButtonLabels := Stack.GetStringArray(PStart-5);
    Stack.SetInt(PStart, LoggedTaskDialogMsgBox('', Stack.GetString(PStart-1), Stack.GetString(PStart-2), GetMsgBoxCaption, TMsgBoxType(Stack.GetInt(PStart-3)), Stack.GetInt(PStart-4), ButtonLabels, Stack.GetInt(PStart-6), Suppressible, Default));
  end else if Proc.Name = 'ISWIN64' then begin
    Stack.SetBool(PStart, IsWin64);
  end else if Proc.Name = 'IS64BITINSTALLMODE' then begin
    Stack.SetBool(PStart, Is64BitInstallMode);
  end else if Proc.Name = 'PROCESSORARCHITECTURE' then begin
    Stack.SetInt(PStart, Integer(ProcessorArchitecture));
  end else if (Proc.Name = 'ISARM32COMPATIBLE') or (Proc.Name = 'ISARM64') or
              (Proc.Name = 'ISX64') or (Proc.Name = 'ISX64OS') or (Proc.Name = 'ISX64COMPATIBLE') or
              (Proc.Name = 'ISX86') or (Proc.Name = 'ISX86OS') or (Proc.Name = 'ISX86COMPATIBLE') then begin
    var ArchitectureIdentifier := LowerCase(Copy(String(Proc.Name), 3, MaxInt));
    Stack.SetBool(PStart, EvalArchitectureIdentifier(ArchitectureIdentifier));
  end else if Proc.Name = 'CUSTOMMESSAGE' then begin
    Stack.SetString(PStart, CustomMessage(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'RMSESSIONSTARTED' then begin
    Stack.SetBool(PStart, RmSessionStarted);
  end else if Proc.Name = 'REGISTEREXTRACLOSEAPPLICATIONSRESOURCE' then begin
    Stack.SetBool(PStart, CodeRegisterExtraCloseApplicationsResource(Stack.GetBool(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'GETMAINFORM' then begin
    Stack.SetClass(PStart, GetMainForm);
  end else if Proc.Name = 'GETWIZARDFORM' then begin
    Stack.SetClass(PStart, GetWizardForm);
  end else if (Proc.Name = 'WIZARDISCOMPONENTSELECTED') or (Proc.Name = 'ISCOMPONENTSELECTED') or
              (Proc.Name = 'WIZARDISTASKSELECTED') or (Proc.Name = 'ISTASKSELECTED') then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    StringList := TStringList.Create();
    try
      Components := (Proc.Name = 'WIZARDISCOMPONENTSELECTED') or (Proc.Name = 'ISCOMPONENTSELECTED');
      if Components then
        GetWizardForm.GetSelectedComponents(StringList, False, False)
      else
        GetWizardForm.GetSelectedTasks(StringList, False, False, False);
      S := Stack.GetString(PStart-1);
      StringChange(S, '/', '\');
      if Components then
        Stack.SetBool(PStart, ShouldProcessEntry(StringList, nil, S, '', '', ''))
      else
        Stack.SetBool(PStart, ShouldProcessEntry(nil, StringList, '', S, '', ''));
    finally
      StringList.Free();
    end;
  end else
    Result := False;
end;

function MessagesProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'SETUPMESSAGE' then begin
    Stack.SetString(PStart, SetupMessages[TSetupMessageID(Stack.GetInt(PStart-1))]);
  end else
    Result := False;
end;

function SystemProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
  F: TFile;
  TmpFileSize: Integer64;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'RANDOM' then begin
    Stack.SetInt(PStart, Random(Stack.GetInt(PStart-1)));
  end else if Proc.Name = 'FILESIZE' then begin
    try
      F := TFileRedir.Create(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), fdOpenExisting, faRead, fsReadWrite);
      try
        Stack.SetInt(PStart-2, F.CappedSize);
        Stack.SetBool(PStart, True);
      finally
        F.Free;
      end;
    except
      Stack.SetBool(PStart, False);
    end;
  end else if Proc.Name = 'FILESIZE64' then begin
    try
      F := TFileRedir.Create(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), fdOpenExisting, faRead, fsReadWrite);
      try
        TmpFileSize := F.Size; { Make sure we access F.Size only once }
        Stack.SetInt64(PStart-2, Int64(TmpFileSize.Hi) shl 32 + TmpFileSize.Lo);
        Stack.SetBool(PStart, True);
      finally
        F.Free;
      end;
    except
      Stack.SetBool(PStart, False);
    end;
  end else if Proc.Name = 'SET8087CW' then begin
    Set8087CW(Stack.GetInt(PStart));
  end else if Proc.Name = 'GET8087CW' then begin
    Stack.SetInt(PStart, Get8087CW);
  end else if Proc.Name = 'UTF8ENCODE' then begin
    Stack.SetAnsiString(PStart, Utf8Encode(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'UTF8DECODE' then begin
    Stack.SetString(PStart, UTF8ToString(Stack.GetAnsiString(PStart-1)));
  end else
    Result := False;
end;

type
  { *Must* keep this in synch with ScriptFunc_C }
  TFindRec = record
    Name: String;
    Attributes: LongWord;
    SizeHigh: LongWord;
    SizeLow: LongWord;
    CreationTime: TFileTime;
    LastAccessTime: TFileTime;
    LastWriteTime: TFileTime;
    AlternateName: String;
    FindHandle: THandle;
  end;

function SysUtilsProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;

  { ExtractRelativePath is not in Delphi 2's SysUtils. Use the one from Delphi 7.01. }
  function NewExtractRelativePath(BaseName, DestName: string): string;
  var
    BasePath, DestPath: string;
    BaseLead, DestLead: PChar;
    BasePtr, DestPtr: PChar;

    function ExtractFilePathNoDrive(const FileName: string): string;
    begin
      Result := PathExtractPath(FileName);
      Delete(Result, 1, Length(PathExtractDrive(FileName)));
    end;

    function Next(var Lead: PChar): PChar;
    begin
      Result := Lead;
      if Result = nil then Exit;
      Lead := PathStrScan(Lead, '\');
      if Lead <> nil then
      begin
        Lead^ := #0;
        Inc(Lead);
      end;
    end;

  begin
    { For consistency with the PathExtract* functions, normalize slashes so
      that forward slashes and multiple slashes work with this function also }
    BaseName := PathNormalizeSlashes(BaseName);
    DestName := PathNormalizeSlashes(DestName);

    if PathCompare(PathExtractDrive(BaseName), PathExtractDrive(DestName)) = 0 then
    begin
      BasePath := ExtractFilePathNoDrive(BaseName);
      UniqueString(BasePath);
      DestPath := ExtractFilePathNoDrive(DestName);
      UniqueString(DestPath);
      BaseLead := Pointer(BasePath);
      BasePtr := Next(BaseLead);
      DestLead := Pointer(DestPath);
      DestPtr := Next(DestLead);
      while (BasePtr <> nil) and (DestPtr <> nil) and (PathCompare(BasePtr, DestPtr) = 0) do
      begin
        BasePtr := Next(BaseLead);
        DestPtr := Next(DestLead);
      end;
      Result := '';
      while BaseLead <> nil do
      begin
        Result := Result + '..\';             { Do not localize }
        Next(BaseLead);
      end;
      if (DestPtr <> nil) and (DestPtr^ <> #0) then
        Result := Result + DestPtr + '\';
      if DestLead <> nil then
        Result := Result + DestLead;     // destlead already has a trailing backslash
      Result := Result + PathExtractName(DestName);
    end
    else
      Result := DestName;
  end;

  { Use our own FileSearch function which includes these improvements over
    Delphi's version:
    - it supports MBCS and uses Path* functions
    - it uses NewFileExistsRedir instead of FileExists
    - it doesn't search the current directory unless it's told to
    - it always returns a fully-qualified path }
  function NewFileSearch(const DisableFsRedir: Boolean;
    const Name, DirList: String): String;
  var
    I, P, L: Integer;
  begin
    { If Name is absolute, drive-relative, or root-relative, don't search DirList }
    if PathDrivePartLengthEx(Name, True) <> 0 then begin
      Result := PathExpand(Name);
      if NewFileExistsRedir(DisableFsRedir, Result) then
        Exit;
    end
    else begin
      P := 1;
      L := Length(DirList);
      while True do begin
        while (P <= L) and (DirList[P] = ';') do
          Inc(P);
        if P > L then
          Break;
        I := P;
        while (P <= L) and (DirList[P] <> ';') do
          Inc(P, PathCharLength(DirList, P));
        Result := PathExpand(PathCombine(Copy(DirList, I, P - I), Name));
        if NewFileExistsRedir(DisableFsRedir, Result) then
          Exit;
      end;
    end;
    Result := '';
  end;

var
  PStart: Cardinal;
  OldName: String;
  NewDateSeparator, NewTimeSeparator: Char;
  OldDateSeparator, OldTimeSeparator: Char;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'BEEP' then begin
    Beep;
  end else if Proc.Name = 'TRIMLEFT' then begin
    Stack.SetString(PStart, TrimLeft(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'TRIMRIGHT' then begin
    Stack.SetString(PStart, TrimRight(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'GETCURRENTDIR' then begin
    Stack.SetString(PStart, GetCurrentDir());
  end else if Proc.Name = 'SETCURRENTDIR' then begin
    Stack.SetBool(PStart, SetCurrentDir(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXPANDFILENAME' then begin
    Stack.SetString(PStart, PathExpand(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXPANDUNCFILENAME' then begin
    Stack.SetString(PStart, ExpandUNCFileName(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXTRACTRELATIVEPATH' then begin
    Stack.SetString(PStart, NewExtractRelativePath(Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'EXTRACTFILEDIR' then begin
    Stack.SetString(PStart, PathExtractDir(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXTRACTFILEDRIVE' then begin
    Stack.SetString(PStart, PathExtractDrive(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXTRACTFILEEXT' then begin
    Stack.SetString(PStart, PathExtractExt(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXTRACTFILENAME' then begin
    Stack.SetString(PStart, PathExtractName(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'EXTRACTFILEPATH' then begin
    Stack.SetString(PStart, PathExtractPath(Stack.GetString(PStart-1)));
  end else if Proc.Name = 'CHANGEFILEEXT' then begin
    Stack.SetString(PStart, PathChangeExt(Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'FILESEARCH' then begin
    Stack.SetString(PStart, NewFileSearch(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'RENAMEFILE' then begin
    OldName := Stack.GetString(PStart-1);
    if not IsProtectedSrcExe(OldName) then
      Stack.SetBool(PStart, MoveFileRedir(ScriptFuncDisableFsRedir, OldName, Stack.GetString(PStart-2)))
    else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'DELETEFILE' then begin
    Stack.SetBool(PStart, DeleteFileRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'CREATEDIR' then begin
    Stack.SetBool(PStart, CreateDirectoryRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'REMOVEDIR' then begin
    Stack.SetBool(PStart, RemoveDirectoryRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1)));
  end else if Proc.Name = 'COMPARESTR' then begin
    Stack.SetInt(PStart, CompareStr(Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'COMPARETEXT' then begin
    Stack.SetInt(PStart, CompareText(Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'SAMESTR' then begin
    Stack.SetBool(PStart, CompareStr(Stack.GetString(PStart-1), Stack.GetString(PStart-2)) = 0);
  end else if Proc.Name = 'SAMETEXT' then begin
    Stack.SetBool(PStart, CompareText(Stack.GetString(PStart-1), Stack.GetString(PStart-2)) = 0);
  end else if Proc.Name = 'GETDATETIMESTRING' then begin
    OldDateSeparator := FormatSettings.DateSeparator;
    OldTimeSeparator := FormatSettings.TimeSeparator;
    try
      NewDateSeparator := Stack.GetString(PStart-2)[1];
      NewTimeSeparator := Stack.GetString(PStart-3)[1];
      if NewDateSeparator <> #0 then
        FormatSettings.DateSeparator := NewDateSeparator;
      if NewTimeSeparator <> #0 then
        FormatSettings.TimeSeparator := NewTimeSeparator;
      Stack.SetString(PStart, FormatDateTime(Stack.GetString(PStart-1), Now()));
    finally
      FormatSettings.TimeSeparator := OldTimeSeparator;
      FormatSettings.DateSeparator := OldDateSeparator;
    end;
  end else if Proc.Name = 'SYSERRORMESSAGE' then begin
    Stack.SetString(PStart, Win32ErrorString(Stack.GetInt(PStart-1)));
  end else
    Result := False;
end;

function VerInfoFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
  VersionNumbers: TFileVersionNumbers;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'GETVERSIONNUMBERS' then begin
    if GetVersionNumbersRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), VersionNumbers) then begin
      Stack.SetInt(PStart-2, VersionNumbers.MS);
      Stack.SetInt(PStart-3, VersionNumbers.LS);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'GETVERSIONCOMPONENTS' then begin
    if GetVersionNumbersRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), VersionNumbers) then begin
      Stack.SetUInt(PStart-2, VersionNumbers.MS shr 16);
      Stack.SetUInt(PStart-3, VersionNumbers.MS and $FFFF);
      Stack.SetUInt(PStart-4, VersionNumbers.LS shr 16);
      Stack.SetUInt(PStart-5, VersionNumbers.LS and $FFFF);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'GETVERSIONNUMBERSSTRING' then begin
    if GetVersionNumbersRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), VersionNumbers) then begin
      Stack.SetString(PStart-2, Format('%u.%u.%u.%u', [VersionNumbers.MS shr 16,
        VersionNumbers.MS and $FFFF, VersionNumbers.LS shr 16, VersionNumbers.LS and $FFFF]));
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'GETPACKEDVERSION' then begin
    if GetVersionNumbersRedir(ScriptFuncDisableFsRedir, Stack.GetString(PStart-1), VersionNumbers) then begin
      Stack.SetInt64(PStart-2, (Int64(VersionNumbers.MS) shl 32) or VersionNumbers.LS);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'PACKVERSIONNUMBERS' then begin
    Stack.SetInt64(PStart, Int64((UInt64(Stack.GetUInt(PStart-1)) shl 32) or Stack.GetUInt(PStart-2)));
  end else if Proc.Name = 'PACKVERSIONCOMPONENTS' then begin
    VersionNumbers.MS := (Stack.GetUInt(PStart-1) shl 16) or (Stack.GetUInt(PStart-2) and $FFFF);
    VersionNumbers.LS := (Stack.GetUInt(PStart-3) shl 16) or (Stack.GetUInt(PStart-4) and $FFFF);
    Stack.SetInt64(PStart, Int64((UInt64(VersionNumbers.MS) shl 32) or VersionNumbers.LS));
  end else if Proc.Name = 'COMPAREPACKEDVERSION' then begin
    Stack.SetInt(PStart, Compare64(Integer64(Stack.GetInt64(PStart-1)), Integer64(Stack.GetInt64(PStart-2))));
  end else if Proc.Name = 'SAMEPACKEDVERSION' then begin
    Stack.SetBool(PStart, Compare64(Integer64(Stack.GetInt64(PStart-1)), Integer64(Stack.GetInt64(PStart-2))) = 0);
  end else if Proc.Name = 'UNPACKVERSIONNUMBERS' then begin
    VersionNumbers.MS := UInt64(Stack.GetInt64(PStart)) shr 32;
    VersionNumbers.LS := UInt64(Stack.GetInt64(PStart)) and $FFFFFFFF;
    Stack.SetUInt(PStart-1, VersionNumbers.MS);
    Stack.SetUInt(PStart-2, VersionNumbers.LS);
  end else if Proc.Name = 'UNPACKVERSIONCOMPONENTS' then begin
    VersionNumbers.MS := UInt64(Stack.GetInt64(PStart)) shr 32;
    VersionNumbers.LS := UInt64(Stack.GetInt64(PStart)) and $FFFFFFFF;
    Stack.SetUInt(PStart-1, VersionNumbers.MS shr 16);
    Stack.SetUInt(PStart-2, VersionNumbers.MS and $FFFF);
    Stack.SetUInt(PStart-3, VersionNumbers.LS shr 16);
    Stack.SetUInt(PStart-4, VersionNumbers.LS and $FFFF);
  end else if Proc.Name = 'VERSIONTOSTR' then begin
    VersionNumbers.MS := UInt64(Stack.GetInt64(PStart-1)) shr 32;
    VersionNumbers.LS := UInt64(Stack.GetInt64(PStart-1)) and $FFFFFFFF;
    Stack.SetString(PStart, Format('%u.%u.%u.%u', [VersionNumbers.MS shr 16,
      VersionNumbers.MS and $FFFF, VersionNumbers.LS shr 16, VersionNumbers.LS and $FFFF]));
  end else if Proc.Name = 'STRTOVERSION' then begin
    if StrToVersionNumbers(Stack.GetString(PStart-1), VersionNumbers) then begin
      Stack.SetInt64(PStart-2, (Int64(VersionNumbers.MS) shl 32) or VersionNumbers.LS);
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else
    Result := False;
end;

type
  TDllProc = function(const Param1, Param2: Longint): Longint; stdcall;

function WindowsProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
  DllProc: TDllProc;
  DllHandle: THandle;
  S: AnsiString;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'SLEEP' then begin
    Sleep(Stack.GetInt(PStart));
  end else if Proc.Name = 'FINDWINDOWBYCLASSNAME' then begin
    Stack.SetInt(PStart, FindWindow(PChar(Stack.GetString(PStart-1)), nil));
  end else if Proc.Name = 'FINDWINDOWBYWINDOWNAME' then begin
    Stack.SetInt(PStart, FindWindow(nil, PChar(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'SENDMESSAGE' then begin
    Stack.SetInt(PStart, SendMessage(Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3), Stack.GetInt(PStart-4)));
  end else if Proc.Name = 'POSTMESSAGE' then begin
    Stack.SetBool(PStart, PostMessage(Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3), Stack.GetInt(PStart-4)));
  end else if Proc.Name = 'SENDNOTIFYMESSAGE' then begin
    Stack.SetBool(PStart, SendNotifyMessage(Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3), Stack.GetInt(PStart-4)));
  end else if Proc.Name = 'REGISTERWINDOWMESSAGE' then begin
    Stack.SetInt(PStart, RegisterWindowMessage(PChar(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'SENDBROADCASTMESSAGE' then begin
    Stack.SetInt(PStart, SendMessage(HWND_BROADCAST, Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3)));
  end else if Proc.Name = 'POSTBROADCASTMESSAGE' then begin
    Stack.SetBool(PStart, PostMessage(HWND_BROADCAST, Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3)));
  end else if Proc.Name = 'SENDBROADCASTNOTIFYMESSAGE' then begin
    Stack.SetBool(PStart, SendNotifyMessage(HWND_BROADCAST, Stack.GetInt(PStart-1), Stack.GetInt(PStart-2), Stack.GetInt(PStart-3)));
  end else if Proc.Name = 'LOADDLL' then begin
    DllHandle := SafeLoadLibrary(Stack.GetString(PStart-1), SEM_NOOPENFILEERRORBOX);
    if DllHandle <> 0 then
      Stack.SetInt(PStart-2, 0)
    else
      Stack.SetInt(PStart-2, GetLastError());
    Stack.SetInt(PStart, DllHandle);
  end else if Proc.Name = 'CALLDLLPROC' then begin
    @DllProc := GetProcAddress(Stack.GetInt(PStart-1), PChar(Stack.GetString(PStart-2)));
    if Assigned(DllProc) then begin
      Stack.SetInt(PStart-5, DllProc(Stack.GetInt(PStart-3), Stack.GetInt(PStart-4)));
      Stack.SetBool(PStart, True);
    end else
      Stack.SetBool(PStart, False);
  end else if Proc.Name = 'FREEDLL' then begin
    Stack.SetBool(PStart, FreeLibrary(Stack.GetInt(PStart-1)));
  end else if Proc.Name = 'CREATEMUTEX' then begin
    Windows.CreateMutex(nil, False, PChar(Stack.GetString(PStart)));
  end else if Proc.Name = 'OEMTOCHARBUFF' then begin
    S := Stack.GetAnsiString(PStart);
    OemToCharBuffA(PAnsiChar(S), PAnsiChar(S), Length(S));
    Stack.SetAnsiString(PStart, S);
  end else if Proc.Name = 'CHARTOOEMBUFF' then begin
    S := Stack.GetAnsiString(PStart);
    CharToOemBuffA(PAnsiChar(S), PAnsiChar(S), Length(S));
    Stack.SetAnsiString(PStart, S);
  end else
    Result := False;
end;

function Ole2Proc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
begin
  Result := True;

  if Proc.Name = 'COFREEUNUSEDLIBRARIES' then begin
    CoFreeUnusedLibraries;
  end else
    Result := False;
end;

function LoggingFuncProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;
var
  PStart: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'LOG' then begin
    Log(Stack.GetString(PStart));
  end else
    Result := False;
end;

{ Other }
var
  ASMInliners: array of Pointer;

function OtherProc(Caller: TPSExec; Proc: TPSExternalProcRec; Global, Stack: TPSStack): Boolean;

  function GetExceptionMessage: String;
  var
    Code: TPSError;
    E: TObject;
  begin
    Code := Caller.LastEx;
    if Code = erNoError then
      Result := '(There is no current exception)'
    else begin
      E := Caller.LastExObject;
      if Assigned(E) and (E is Exception) then
        Result := Exception(E).Message
      else
        Result := String(PSErrorToString(Code, Caller.LastExParam));
    end;
  end;

  function GetCodePreviousData(const ExpandedAppID, ValueName, DefaultValueData: String): String;
  begin
    { do not localize or change the following string }
    Result := GetPreviousData(ExpandedAppId, 'Inno Setup CodeFile: ' + ValueName, DefaultValueData);
  end;

  { Also see RegisterUninstallInfo in Install.pas }
  function SetCodePreviousData(const PreviousDataKey: HKEY; const ValueName, ValueData: String): Boolean;
  begin
    if ValueData <> '' then begin
      { do not localize or change the following string }
      Result := RegSetValueEx(PreviousDataKey, PChar('Inno Setup CodeFile: ' + ValueName), 0, REG_SZ, PChar(ValueData), (Length(ValueData)+1)*SizeOf(ValueData[1])) = ERROR_SUCCESS
    end else
      Result := True;
  end;

  function LoadStringFromFile(const FileName: String; var S: AnsiString;
    const Sharing: TFileSharing): Boolean;
  var
    F: TFile;
    N: Cardinal;
  begin
    try
      F := TFileRedir.Create(ScriptFuncDisableFsRedir, FileName, fdOpenExisting, faRead, Sharing);
      try
        N := F.CappedSize;
        SetLength(S, N);
        F.ReadBuffer(S[1], N);
      finally
        F.Free;
      end;

      Result := True;
    except
      Result := False;
    end;
  end;

  function LoadStringsFromFile(const FileName: String; const Stack: TPSStack;
    const ItemNo: Longint; const Sharing: TFileSharing): Boolean;
  var
    F: TTextFileReader;
  begin
    try
      F := TTextFileReaderRedir.Create(ScriptFuncDisableFsRedir, FileName, fdOpenExisting, faRead, Sharing);
      try
        var ArrayBuilder := Stack.InitArrayBuilder(ItemNo);
        while not F.Eof do
          ArrayBuilder.Add(F.ReadLine);
      finally
        F.Free;
      end;

      Result := True;
    except
      Result := False;
    end;
  end;

  function SaveStringToFile(const FileName: String; const S: AnsiString; Append: Boolean): Boolean;
  var
    F: TFile;
  begin
    try
      if Append then
        F := TFileRedir.Create(ScriptFuncDisableFsRedir, FileName, fdOpenAlways, faWrite, fsNone)
      else
        F := TFileRedir.Create(ScriptFuncDisableFsRedir, FileName, fdCreateAlways, faWrite, fsNone);
      try
        F.SeekToEnd;
        F.WriteAnsiString(S);
      finally
        F.Free;
      end;

      Result := True;
    except
      Result := False;
    end;
  end;

  function SaveStringsToFile(const FileName: String; const Stack: TPSStack;
    const ItemNo: Longint; Append, UTF8, UTF8WithoutBOM: Boolean): Boolean;
  var
    F: TTextFileWriter;
  begin
    try
      if Append then
        F := TTextFileWriterRedir.Create(ScriptFuncDisableFsRedir, FileName, fdOpenAlways, faWrite, fsNone)
      else
        F := TTextFileWriterRedir.Create(ScriptFuncDisableFsRedir, FileName, fdCreateAlways, faWrite, fsNone);
      try
        if UTF8 and UTF8WithoutBOM then
          F.UTF8WithoutBOM := UTF8WithoutBOM;
        var ArrayEnumerator := Stack.InitArrayEnumerator(ItemNo);
        while ArrayEnumerator.HasNext do begin
          var S := ArrayEnumerator.Next;
          if not UTF8 then
            F.WriteAnsiLine(AnsiString(S))
          else
            F.WriteLine(S);
        end;
      finally
        F.Free;
      end;

      Result := True;
    except
      Result := False;
    end;
  end;
  
  function CreateCallback(P: PPSVariantProcPtr): LongWord;
  var
    ProcRec: TPSInternalProcRec;
    Method: TMethod;
    Inliner: TASMInline;
    ParamCount, SwapFirst, SwapLast: Integer;
    S: tbtstring;
  begin
    { ProcNo 0 means nil was passed by the script }
    if P.ProcNo = 0 then
      InternalError('Invalid Method value');

    { Calculate parameter count of our proc, will need this later. }
    ProcRec := Caller.GetProcNo(P.ProcNo) as TPSInternalProcRec;
    S := ProcRec.ExportDecl;
    GRFW(S);
    ParamCount := 0;
    while S <> '' do begin
      Inc(ParamCount);
      GRFW(S);
    end;

    { Turn our proc into a callable TMethod - its Code will point to
      ROPS' MyAllMethodsHandler and its Data to a record identifying our proc.
      When called, MyAllMethodsHandler will use the record to call our proc. }
    Method := MkMethod(Caller, P.ProcNo);

    { Wrap our TMethod with a dynamically generated stdcall callback which will
      do two things:
      -Remember the Data pointer which MyAllMethodsHandler needs.
      -Handle the calling convention mismatch.

      Based on InnoCallback by Sherlock Software, see
      http://www.sherlocksoftware.org/page.php?id=54 and
      https://github.com/thenickdude/InnoCallback. }
    Inliner := TASMInline.create;
    try
      Inliner.Pop(EAX); //get the retptr off the stack

      SwapFirst := 2;
      SwapLast := ParamCount-1;

      //Reverse the order of parameters from param3 onwards in the stack
      while SwapLast > SwapFirst do begin
        Inliner.Mov(ECX, Inliner.Addr(ESP, SwapFirst * 4)); //load the first item of the pair
        Inliner.Mov(EDX, Inliner.Addr(ESP, SwapLast * 4)); //load the last item of the pair
        Inliner.Mov(Inliner.Addr(ESP, SwapFirst * 4), EDX);
        Inliner.Mov(Inliner.Addr(ESP, SwapLast * 4), ECX);
        Inc(SwapFirst);
        Dec(SwapLast);
      end;

      if ParamCount >= 1 then
        Inliner.Pop(EDX); //load param1
      if ParamCount >= 2 then
        Inliner.Pop(ECX); //load param2

      Inliner.Push(EAX); //put the retptr back onto the stack

      Inliner.Mov(EAX, LongWord(Method.Data)); //Load the self ptr

      Inliner.Jmp(Method.Code); //jump to the wrapped proc

      SetLength(ASMInliners, Length(ASMInliners) + 1);
      ASMInliners[High(ASMInliners)] := Inliner.SaveAsMemory;
      Result := LongWord(ASMInliners[High(ASMInliners)]);
    finally
      Inliner.Free;
    end;
  end;

var
  PStart: Cardinal;
  TypeEntry: PSetupTypeEntry;
  StringList: TStringList;
  S: String;
  AnsiS: AnsiString;
  ErrorCode: Cardinal;
begin
  PStart := Stack.Count-1;
  Result := True;

  if Proc.Name = 'BRINGTOFRONTANDRESTORE' then begin
    Application.BringToFront();
    Application.Restore();
  end else if Proc.Name = 'WIZARDDIRVALUE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetString(PStart, RemoveBackslashUnlessRoot(GetWizardForm.DirEdit.Text));
  end else if Proc.Name = 'WIZARDGROUPVALUE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetString(PStart, RemoveBackslashUnlessRoot(GetWizardForm.GroupEdit.Text));
  end else if Proc.Name = 'WIZARDNOICONS' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetBool(PStart, GetWizardForm.NoIconsCheck.Checked);
  end else if Proc.Name = 'WIZARDSETUPTYPE' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    TypeEntry := GetWizardForm.GetSetupType();
    if TypeEntry <> nil then begin
      if Stack.GetBool(PStart-1) then
        Stack.SetString(PStart, TypeEntry.Description)
      else
        Stack.SetString(PStart, TypeEntry.Name);
    end
    else
      Stack.SetString(PStart, '');
  end else if (Proc.Name = 'WIZARDSELECTEDCOMPONENTS') or (Proc.Name = 'WIZARDSELECTEDTASKS') then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    StringList := TStringList.Create();
    try
      if Proc.Name = 'WIZARDSELECTEDCOMPONENTS' then
        GetWizardForm.GetSelectedComponents(StringList, Stack.GetBool(PStart-1), False)
      else
        GetWizardForm.GetSelectedTasks(StringList, Stack.GetBool(PStart-1), False, False);
      Stack.SetString(PStart, StringsToCommaString(StringList));
    finally
      StringList.Free();
    end;
  end else if (Proc.Name = 'WIZARDSELECTCOMPONENTS') or (Proc.Name = 'WIZARDSELECTTASKS') then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    StringList := TStringList.Create();
    try
      S := Stack.GetString(PStart);
      StringChange(S, '/', '\');
      SetStringsFromCommaString(StringList, S);
      if Proc.Name = 'WIZARDSELECTCOMPONENTS' then
        GetWizardForm.SelectComponents(StringList)
      else
        GetWizardForm.SelectTasks(StringList);
    finally
      StringList.Free();
    end;
  end else if Proc.Name = 'WIZARDSILENT' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    Stack.SetBool(PStart, InstallMode <> imNormal);
  end else if Proc.Name = 'ISUNINSTALLER' then begin
    Stack.SetBool(PStart, IsUninstaller);
  end else if Proc.Name = 'UNINSTALLSILENT' then begin
    if not IsUninstaller then
      NoSetupFuncError(Proc.Name);
    Stack.SetBool(PStart, UninstallSilent);
  end else if Proc.Name = 'CURRENTFILENAME' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    if CheckOrInstallCurrentFilename <> '' then
      Stack.SetString(PStart, CheckOrInstallCurrentFilename)
    else
      InternalError('An attempt was made to call the "CurrentFilename" function from outside a "Check", "BeforeInstall" or "AfterInstall" event function belonging to a "[Files]" entry');
  end else if Proc.Name = 'CURRENTSOURCEFILENAME' then begin
    if IsUninstaller then
      NoUninstallFuncError(Proc.Name);
    if CheckOrInstallCurrentSourceFilename <> '' then
      Stack.SetString(PStart, CheckOrInstallCurrentSourceFilename)
    else
      InternalError('An attempt was made to call the "CurrentSourceFilename" function from outside a "Check", "BeforeInstall" or "AfterInstall" event function belonging to a "[Files]" entry with flag "external"');
  end else if Proc.Name = 'CASTSTRINGTOINTEGER' then begin
    Stack.SetInt(PStart, Integer(PChar(Stack.GetString(PStart-1))));
  end else if Proc.Name = 'CASTINTEGERTOSTRING' then begin
    Stack.SetString(PStart, String(PChar(Stack.GetInt(PStart-1))));
  end else if Proc.Name = 'ABORT' then begin
    Abort;
  end else if Proc.Name = 'GETEXCEPTIONMESSAGE' then begin
    Stack.SetString(PStart, GetExceptionMessage);
  end else if Proc.Name = 'RAISEEXCEPTION' then begin
    raise Exception.Create(Stack.GetString(PStart));
  end else if Proc.Name = 'SHOWEXCEPTIONMESSAGE' then begin
    TMainForm.ShowExceptionMsg(AddPeriod(GetExceptionMessage));
  end else if Proc.Name = 'TERMINATED' then begin
    Stack.SetBool(PStart, Application.Terminated);
  end else if Proc.Name = 'GETPREVIOUSDATA' then begin
    if IsUninstaller then
      Stack.SetString(PStart, GetCodePreviousData(UninstallExpandedAppId, Stack.GetString(PStart-1), Stack.GetString(PStart-2)))
    else
      Stack.SetString(PStart, GetCodePreviousData(ExpandConst(SetupHeader.AppId), Stack.GetString(PStart-1), Stack.GetString(PStart-2)));
  end else if Proc.Name = 'SETPREVIOUSDATA' then begin
    Stack.SetBool(PStart, SetCodePreviousData(Stack.GetInt(PStart-1), Stack.GetString(PStart-2), Stack.GetString(PStart-3)));
  end else if Proc.Name = 'LOADSTRINGFROMFILE' then begin
    AnsiS := Stack.GetAnsiString(PStart-2);
    Stack.SetBool(PStart, LoadStringFromFile(Stack.GetString(PStart-1), AnsiS, fsRead));
    Stack.SetAnsiString(PStart-2, AnsiS);
  end else if Proc.Name = 'LOADSTRINGFROMLOCKEDFILE' then begin
    AnsiS := Stack.GetAnsiString(PStart-2);
    Stack.SetBool(PStart, LoadStringFromFile(Stack.GetString(PStart-1), AnsiS, fsReadWrite));
    Stack.SetAnsiString(PStart-2, AnsiS);
  end else if Proc.Name = 'LOADSTRINGSFROMFILE' then begin
    Stack.SetBool(PStart, LoadStringsFromFile(Stack.GetString(PStart-1), Stack, PStart-2, fsRead));
  end else if Proc.Name = 'LOADSTRINGSFROMLOCKEDFILE' then begin
    Stack.SetBool(PStart, LoadStringsFromFile(Stack.GetString(PStart-1), Stack, PStart-2, fsReadWrite));
  end else if Proc.Name = 'SAVESTRINGTOFILE' then begin
    Stack.SetBool(PStart, SaveStringToFile(Stack.GetString(PStart-1), Stack.GetAnsiString(PStart-2), Stack.GetBool(PStart-3)));
  end else if Proc.Name = 'SAVESTRINGSTOFILE' then begin
    Stack.SetBool(PStart, SaveStringsToFile(Stack.GetString(PStart-1), Stack, PStart-2, Stack.GetBool(PStart-3), False, False));
  end else if Proc.Name = 'SAVESTRINGSTOUTF8FILE' then begin
    Stack.SetBool(PStart, SaveStringsToFile(Stack.GetString(PStart-1), Stack, PStart-2, Stack.GetBool(PStart-3), True, False));
  end else if Proc.Name = 'SAVESTRINGSTOUTF8FILEWITHOUTBOM' then begin
    Stack.SetBool(PStart, SaveStringsToFile(Stack.GetString(PStart-1), Stack, PStart-2, Stack.GetBool(PStart-3), True, True));
  end else if Proc.Name = 'ENABLEFSREDIRECTION' then begin
    Stack.SetBool(PStart, not ScriptFuncDisableFsRedir);
    if Stack.GetBool(PStart-1) then
      ScriptFuncDisableFsRedir := False
    else begin
      if not IsWin64 then
        InternalError('Cannot disable FS redirection on this version of Windows');
      ScriptFuncDisableFsRedir := True;
    end;
  end else if Proc.Name = 'GETUNINSTALLPROGRESSFORM' then begin
    Stack.SetClass(PStart, GetUninstallProgressForm);
  end else if Proc.Name = 'CREATECALLBACK' then begin
    Stack.SetInt(PStart, CreateCallback(Stack.Items[PStart-1]));
  end else if Proc.Name = 'ISDOTNETINSTALLED' then begin
    Stack.SetBool(PStart, IsDotNetInstalled(InstallDefaultRegView, TDotNetVersion(Stack.GetInt(PStart-1)), Stack.GetInt(PStart-2)));
  end else if Proc.Name = 'ISMSIPRODUCTINSTALLED' then begin
    Stack.SetBool(PStart, IsMsiProductInstalled(Stack.GetString(PStart-1), Stack.GetInt64(PStart-2), ErrorCode));
    if ErrorCode <> 0 then
      raise Exception.Create(Win32ErrorString(ErrorCode));
  end else if Proc.Name = 'INITIALIZEBITMAPIMAGEFROMICON' then begin
    var AscendingTrySizes := Stack.GetIntArray(PStart-4);
    Stack.SetBool(PStart, TBitmapImage(Stack.GetClass(PStart-1)).InitializeFromIcon(0, PChar(Stack.GetString(PStart-2)), Stack.GetInt(PStart-3), AscendingTrySizes));
  end else if Proc.Name = 'EXTRACT7ZIPARCHIVE' then begin
    Extract7ZipArchive(Stack.GetString(PStart), Stack.GetString(PStart-1), Stack.GetBool(PStart-2), TOnExtractionProgress(Stack.GetProc(PStart-3, Caller)));
  end else if Proc.Name = 'DEBUGGING' then begin
    Stack.SetBool(PStart, Debugging);
  end else if Proc.Name = 'STRINGJOIN' then begin
    var Values := Stack.GetStringArray(PStart-2);
    Stack.SetString(PStart, String.Join(Stack.GetString(PStart-1), Values));
  end else if (Proc.Name = 'STRINGSPLIT') or (Proc.Name = 'STRINGSPLITEX') then begin
    var Separators := Stack.GetStringArray(PStart-2);
    var Parts: TArray<String>;
    if Proc.Name = 'STRINGSPLITEX' then begin
      var Quote := Stack.GetString(PStart-3)[1];
      Parts := Stack.GetString(PStart-1).Split(Separators, Quote, Quote, TStringSplitOptions(Stack.GetInt(PStart-4)))
    end else
      Parts := Stack.GetString(PStart-1).Split(Separators, TStringSplitOptions(Stack.GetInt(PStart-3)));
    Stack.SetArray(PStart, Parts);
  end else
    Result := False;
end;

{---}

procedure FindDataToFindRec(const FindData: TWin32FindData;
  var FindRec: TFindRec);
begin
  FindRec.Name := FindData.cFileName;
  FindRec.Attributes := FindData.dwFileAttributes;
  FindRec.SizeHigh := FindData.nFileSizeHigh;
  FindRec.SizeLow := FindData.nFileSizeLow;
  FindRec.CreationTime := FindData.ftCreationTime;
  FindRec.LastAccessTime := FindData.ftLastAccessTime;
  FindRec.LastWriteTime := FindData.ftLastWriteTime;
  FindRec.AlternateName := FindData.cAlternateFileName;
end;

function _FindFirst(const FileName: String; var FindRec: TFindRec): Boolean;
var
  FindHandle: THandle;
  FindData: TWin32FindData;
begin
  FindHandle := FindFirstFileRedir(ScriptFuncDisableFsRedir, FileName, FindData);
  if FindHandle <> INVALID_HANDLE_VALUE then begin
    FindRec.FindHandle := FindHandle;
    FindDataToFindRec(FindData, FindRec);
    Result := True;
  end
  else begin
    FindRec.FindHandle := 0;
    Result := False;
  end;
end;

function _FindNext(var FindRec: TFindRec): Boolean;
var
  FindData: TWin32FindData;
begin
  Result := (FindRec.FindHandle <> 0) and FindNextFile(FindRec.FindHandle, FindData);
  if Result then
    FindDataToFindRec(FindData, FindRec);
end;

procedure _FindClose(var FindRec: TFindRec);
begin
  if FindRec.FindHandle <> 0 then begin
    Windows.FindClose(FindRec.FindHandle);
    FindRec.FindHandle := 0;
  end;
end;

function _FmtMessage(const S: String; const Args: array of String): String;
begin
  Result := FmtMessage(PChar(S), Args);
end;

type
  { *Must* keep this in synch with ScriptFunc_C }
  TWindowsVersion = packed record
    Major: Cardinal;
    Minor: Cardinal;
    Build: Cardinal;
    ServicePackMajor: Cardinal;
    ServicePackMinor: Cardinal;
    NTPlatform: Boolean;
    ProductType: Byte;
    SuiteMask: Word;
  end;

procedure _GetWindowsVersionEx(var Version: TWindowsVersion);
begin
  Version.Major := WindowsVersion shr 24;
  Version.Minor := (WindowsVersion shr 16) and $FF;
  Version.Build := WindowsVersion and $FFFF;
  Version.ServicePackMajor := Hi(NTServicePackLevel);
  Version.ServicePackMinor := Lo(NTServicePackLevel);
  Version.NTPlatform := True;
  Version.ProductType := WindowsProductType;
  Version.SuiteMask := WindowsSuiteMask;
end;

procedure ScriptFuncLibraryRegister_R(ScriptInterpreter: TPSExec);
{$IFDEF DEBUG}
var
  Count: Integer;
{$ENDIF}

  procedure RegisterFunctionTable(const FunctionTable: array of AnsiString;
    const ProcPtr: TPSProcPtr);
  begin
    for var Func in FunctionTable do
      ScriptInterpreter.RegisterFunctionName(ExtractScriptFuncName(Func),
        ProcPtr, nil, nil);
    {$IFDEF DEBUG}
    Inc(Count);
    {$ENDIF}
  end;

  procedure RegisterDelphiFunction(ProcPtr: Pointer; const Name: AnsiString);
  begin
    ScriptInterpreter.RegisterDelphiFunction(ProcPtr, Name, cdRegister);
    {$IFDEF DEBUG}
    Inc(Count);
    {$ENDIF}
  end;

begin
  { The following should register all tables in ScriptFuncTables }
  {$IFDEF DEBUG}
  Count := 0;
  {$ENDIF}
  RegisterFunctionTable(ScriptFuncTables[sftScriptDlg], @ScriptDlgProc);
  RegisterFunctionTable(ScriptFuncTables[sftNewDiskForm], @NewDiskFormProc);
  RegisterFunctionTable(ScriptFuncTables[sftBrowseFunc], @BrowseFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftCommonFuncVcl], @CommonFuncVclProc);
  RegisterFunctionTable(ScriptFuncTables[sftCommonFunc], @CommonFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftInstall], @InstallProc);
  RegisterFunctionTable(ScriptFuncTables[sftInstFunc], @InstFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftInstFuncOle], @InstFuncOleProc);
  RegisterFunctionTable(ScriptFuncTables[sftMainFunc], @MainFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftMessages], @MessagesProc);
  RegisterFunctionTable(ScriptFuncTables[sftSystem], @SystemProc);
  RegisterFunctionTable(ScriptFuncTables[sftSysUtils], @SysUtilsProc);
  RegisterFunctionTable(ScriptFuncTables[sftVerInfoFunc], @VerInfoFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftWindows], @WindowsProc);
  RegisterFunctionTable(ScriptFuncTables[sftOle2], @Ole2Proc);
  RegisterFunctionTable(ScriptFuncTables[sftLoggingFunc], @LoggingFuncProc);
  RegisterFunctionTable(ScriptFuncTables[sftOther], @OtherProc);
  {$IFDEF DEBUG}
  if Count <> Length(ScriptFuncTables) then
    raise Exception.Create('Count <> Length(ScriptFuncTables)');
  {$ENDIF}

  { The following should register all functions in ScriptDelphiFuncTable }
  {$IFDEF DEBUG}
  Count := 0;
  {$ENDIF}
  RegisterDelphiFunction(@_FindFirst, 'FindFirst');
  RegisterDelphiFunction(@_FindNext, 'FindNext');
  RegisterDelphiFunction(@_FindClose, 'FindClose');
  RegisterDelphiFunction(@_FmtMessage, 'FmtMessage');
  RegisterDelphiFunction(@Format, 'Format');
  RegisterDelphiFunction(@_GetWindowsVersionEx, 'GetWindowsVersionEx');
  {$IFDEF DEBUG}
  if Count <> Length(DelphiScriptFuncTable) then
    raise Exception.Create('Count <> Length(DelphiScriptFuncTable)');
  {$ENDIF}
end;

procedure FreeASMInliners;
var
  I: Integer;
begin
  for I := 0 to High(ASMInliners) do
    FreeMem(ASMInliners[I]);
  SetLength(ASMInliners, 0);
end;

initialization
finalization
  FreeASMInliners;
end.
