-- =============================================
-- 預存程序名稱: [dbo].[GLSPEC_SyncDJToInternalList]
-- 功能說明: 將 Dow Jones (DJ) 黑名單資料同步至內部制裁名單
--           分為兩大部分:
--           1. 主要制裁名單同步至 BSADB.dbo.OFAC_GLSpec (依傳入的 @GroupId)
--           2. Sanctions Control & Ownership (SCO) 清單同步至 BSADBTW..OFAC_SPEC (固定 GROUPID=27)
-- 參數:
--   @GroupId BIGINT - 目標群組ID (用於 OFAC_GLSpec 的 GROUPID 欄位)
-- 執行時機: 定期排程或手動執行，用於更新最新 Dow Jones 制裁名單
-- 注意事項: 
--   - 使用 MERGE 陳述式處理新增、更新、軟刪除 (DInd)
--   - 所有操作會記錄至對應的 Log 表 (OFAC_GLSpec_Log / OFAC_SPEC_LOG)
--   - 2025/12/19 已將 Sanctions Control & Ownership 清單從主流程獨立出來
-- =============================================
USE [BSADB]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[GLSPEC_SyncDJToInternalList]
    @GroupId BIGINT
AS
BEGIN
    -- ============================================
    -- 1. 宣告變數並取得系統設定值
    -- ============================================
    DECLARE @OtherIdentMthCode VARCHAR(2),   -- 其他識別方法代碼 (OTHIND = 'Y')
            @Filter_Alt_Str INT              -- Dow Jones AltStrength 過濾條件值
            
    -- 取得「其他識別方法代碼」(用於 IdentificationType)
    SELECT @OtherIdentMthCode = IDENTCODE 
    FROM dbo.IDENTMTHD_DIM 
    WHERE OTHIND = 'Y' 
    
    -- 取得 Dow Jones 同步至 GLSpec 的 AltStrengthBitCode 過濾門檻
    SELECT @Filter_Alt_Str = CtrlVal 
    FROM dbo.PO_DIMData 
    WHERE Module = 'DJ' 
      AND CtrlKey = 'DJ_ToGLSPEC_ALT_STR'

    -- ============================================
    -- 2. 建立主要黑名單暫存表 (#tempDJBlacklist / #tempDJBlacklistDetails)
    -- ============================================
    -- #tempDJBlacklist: 存放符合條件的主要黑名單基本資料 (EntNum, SdnName, 最新更新日期)
    IF OBJECT_ID('tempdb..#tempDJBlacklist') IS NOT NULL
        DROP TABLE #tempDJBlacklist
        
    IF OBJECT_ID('tempdb..#tempDJBlacklistDetails') IS NOT NULL
        DROP TABLE #tempDJBlacklistDetails

    CREATE TABLE #tempDJBlacklist (
        EntNum      INT NOT NULL,
        SdnName     NVARCHAR(350) NOT NULL,
        UpdatedDate VARCHAR(8) NOT NULL
    )

    -- #tempDJBlacklistDetails: 存放合併後的詳細資料 (地址、識別碼、出生日期、性別等)
    CREATE TABLE #tempDJBlacklistDetails (
        EntNum       INT NOT NULL,
        SdnName      NVARCHAR(350) NOT NULL,
        UpdatedDate  VARCHAR(8) NOT NULL,
        Address      NVARCHAR(400),
        City         NVARCHAR(200),
        Country      NVARCHAR(100),
        IdentType    VARCHAR(2),
        IdentNumber  NVARCHAR(44),
        DOB          VARCHAR(8),
        Gender       NVARCHAR(7)
    )

    -- ============================================
    -- 3. 從 DJ_List_Data_A 取得符合條件的主要黑名單資料
    --    條件: NamePropertyBitCode 第0位元為1 且 AltStrengthBitCode 符合過濾條件
    -- ============================================
    INSERT INTO #tempDJBlacklist (EntNum, SdnName, UpdatedDate)
    SELECT A.EntNum, 
           A.SdnName, 
           MAX(A.UpdatedDate) AS UpdatedDate 
    FROM BSADB.dbo.DJ_List_Data_A A 
    WHERE A.NamePropertyBitCode & 1 > 0 
      AND A.AltStrengthBitCode & @Filter_Alt_Str <> 0
    GROUP BY A.EntNum, A.SdnName 

    -- ============================================
    -- 4. 使用 CTE 取得地址、識別碼、出生日期、性別等詳細資料
    --    (每個 Entity 只取第一筆資料 - RowId = 1)
    -- ============================================
    ;WITH TempAddress AS (
        -- 地址資料 (Address, City, Country)
        SELECT A.EntityId, 
               A.Address, 
               A.City, 
               A.AddressCountry, 
               ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.Id) AS 'RowId'
        FROM BSADB.dbo.DJ_Address A WITH(NOLOCK) 
        WHERE A.Deleted = 0  
          AND EXISTS (SELECT 1 FROM #tempDJBlacklist X WHERE A.EntityId = X.EntNum)
    ),
    TempIdent AS (
        -- 識別碼資料 (使用 OtherIdentMthCode 作為 IdentType)
        SELECT EntityId, 
               CASE WHEN ISNULL(IdentificationType,'') = '' THEN NULL 
                    ELSE @OtherIdentMthCode 
               END AS 'IdentificationType', 
               IdentificationNumber, 
               ROW_NUMBER() OVER (PARTITION BY EntityId ORDER BY Id) AS 'RowId' 
        FROM BSADB.dbo.DJ_IdentificationTypeInfo A WITH(NOLOCK) 
        WHERE A.Deleted = 0 
          AND EXISTS (SELECT 1 FROM #tempDJBlacklist X WHERE A.EntityId = X.EntNum)
    ),
    TempDOB AS (
        -- 出生日期資料 (Date of Birth)
        SELECT EntityId, 
               InfoDay, 
               InfoMonth, 
               InfoYear, 
               ROW_NUMBER() OVER (PARTITION BY EntityId ORDER BY Id) AS 'RowId' 
        FROM BSADB.dbo.DJ_DateTypeInfo A WITH(NOLOCK) 
        WHERE A.DateType = 'Date of Birth' 
          AND A.Deleted = 0 
          AND EXISTS (SELECT 1 FROM #tempDJBlacklist X WHERE A.EntityId = X.EntNum)
    ),
    TempGender AS (
        -- 性別資料 (轉換 Male/Female 為 M/F)
        SELECT A.EntityId, 
               CASE 
                   WHEN ISNULL(A.Gender,'') = '' THEN NULL 
                   WHEN ISNULL(A.Gender,'') = 'Male' THEN 'M' 
                   WHEN ISNULL(A.Gender,'') = 'Female' THEN 'F'
               END AS 'Gender', 
               ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.EntityId) AS 'RowId' 
        FROM BSADB.dbo.DJ_Entity A WITH(NOLOCK)
        WHERE A.Deleted = 0 
          AND EXISTS (SELECT 1 FROM #tempDJBlacklist X WITH(NOLOCK) WHERE A.EntityId = X.EntNum)
    )
    -- ============================================
    -- 5. 將詳細資料插入 #tempDJBlacklistDetails
    -- ============================================
    INSERT INTO #tempDJBlacklistDetails (
        EntNum, SdnName, UpdatedDate, Address, City, Country, 
        IdentType, IdentNumber, DOB, Gender
    )
    SELECT A.EntNum, 
           A.SdnName, 
           A.UpdatedDate, 
           B.Address, 
           LEFT(B.City, 100), 
           LEFT(B.AddressCountry, 100),
           C.IdentificationType, 
           LEFT(C.IdentificationNumber, 44), 
           CASE 
               WHEN D.InfoDay IS NULL OR D.InfoMonth IS NULL 
               THEN D.InfoYear 
               ELSE CONVERT(VARCHAR(8), dbo.TryParseDate(D.InfoYear + ' ' + D.InfoMonth + ' ' + D.InfoDay), 112) 
           END, 
           E.Gender
    FROM #tempDJBlacklist A 
        LEFT JOIN TempAddress B ON A.EntNum = B.EntityId AND B.RowId = 1 
        LEFT JOIN TempIdent   C ON A.EntNum = C.EntityId AND C.RowId = 1 
        LEFT JOIN TempDOB     D ON A.EntNum = D.EntityId AND D.RowId = 1 
        LEFT JOIN TempGender  E ON A.EntNum = E.EntityId AND E.RowId = 1

    -- ============================================
    -- 6. MERGE 至 BSADB.dbo.OFAC_GLSpec (主要制裁名單)
    --    - 新增: 來源有但目標沒有 → INSERT (DInd='N')
    --    - 軟刪除: 目標有但來源沒有 → UPDATE DInd='Y'
    --    - 更新: 日期不同或原本已刪除 → UPDATE 並恢復 DInd='N'
    -- ============================================
    ;WITH TargetTable AS (
        SELECT A.spec_name, A.updated_date, A.remark, A.TaxID, A.IDENT, A.IDENTO, A.TaxIDCD, A.IDNUM, 
               A.DInd, A.creUserID, A.STATE, A.ADDRESS, A.COUNTRY,
               A.GROUPID, A.SOURCE, A.EnterFlag, A.ApprovedBy, A.ApprovedDate, 
               A.DelUserID, A.DelDate, A.ApproveDelUserID, A.ApproveDelDate, A.creDate,
               A.updated_date_UTC, A.ApprovedDate_UTC, A.DelDate_UTC, A.ApproveDelDate_UTC, A.creDate_UTC, 
               A.ent_num, A.DOB, A.Gender
        FROM BSADB.dbo.OFAC_GLSpec A 
        WHERE A.GROUPID = @GroupId
    )
    MERGE TargetTable T 
    USING (
        SELECT EntNum, SdnName, UpdatedDate, Address, City, Country, 
               IdentType, IdentNumber, DOB, Gender 
        FROM #tempDJBlacklistDetails
    ) S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
    
    -- 新增 (來源有、目標沒有)
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (spec_name, updated_date, remark, DInd, creUserID, STATE, ADDRESS, COUNTRY, GROUPID, 
                IDENT, IDNUM, DOB, Gender, SOURCE, EnterFlag, 
                ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, 
                creDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, creDate_UTC)
        VALUES (S.SdnName, S.UpdatedDate, S.EntNum, 'N', 'System Admin', ISNULL(S.City,''), 
                S.Address, S.Country, @GroupId, S.IdentType, S.IdentNumber, S.DOB, S.Gender,
                NULL, 'D', 'System Admin', GETDATE(), 'System Admin', GETDATE(), 
                'System Admin', GETDATE(), GETDATE(), GETDATE(), 
                GETUTCDATE(), NULL, NULL, GETUTCDATE())
    
    -- 軟刪除 (目標有、來源沒有，且原本為有效資料)
    WHEN NOT MATCHED BY SOURCE AND T.DInd = 'N' THEN 
        UPDATE SET T.DInd = 'Y', 
                   T.DelUserID = 'System Admin', 
                   T.DelDate = GETDATE(), 
                   T.ApproveDelUserID = 'System Admin', 
                   T.ApproveDelDate = GETDATE(),
                   T.DelDate_UTC = GETUTCDATE()
    
    -- 更新 (日期不同 或 原本已刪除 → 恢復為有效)
    WHEN MATCHED AND (T.DInd = 'Y' OR S.UpdatedDate <> T.updated_date) THEN 
        UPDATE SET T.DInd = 'N', 
                   T.updated_date = S.UpdatedDate, 
                   T.DelUserID = NULL, 
                   T.DelDate = NULL, 
                   T.ApproveDelUserID = NULL, 
                   T.ApproveDelDate = NULL,
                   T.DelDate_UTC = NULL, 
                   T.EnterFlag = 'D', 
                   T.updated_date_UTC = GETUTCDATE(),
                   T.ADDRESS = S.ADDRESS, 
                   T.STATE = ISNULL(S.City,''), 
                   T.COUNTRY = S.Country, 
                   T.IDENT = S.IdentType, 
                   T.IDNUM = S.IdentNumber, 
                   T.DOB = S.DOB, 
                   T.Gender = S.Gender
    
    -- 輸出所有變更記錄至 Log 表
    OUTPUT 
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ent_num ELSE Deleted.ent_num END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.spec_name ELSE Deleted.spec_name END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.updated_date ELSE Deleted.updated_date END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.remark ELSE Deleted.remark END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DInd ELSE Deleted.DInd END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creUserID ELSE Deleted.creUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENTO ELSE Deleted.IDENTO END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.STATE ELSE Deleted.STATE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ADDRESS ELSE Deleted.ADDRESS END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.COUNTRY ELSE Deleted.COUNTRY END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.GROUPID ELSE Deleted.GROUPID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENT ELSE Deleted.IDENT END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDNUM ELSE Deleted.IDNUM END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DOB ELSE Deleted.DOB END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.Gender ELSE Deleted.Gender END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.EnterFlag ELSE Deleted.EnterFlag END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedBy ELSE Deleted.ApprovedBy END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate ELSE Deleted.ApprovedDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelUserID ELSE Deleted.DelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate ELSE Deleted.DelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelUserID ELSE Deleted.ApproveDelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate ELSE Deleted.ApproveDelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creDate ELSE Deleted.creDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.updated_date_UTC ELSE Deleted.updated_date_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate_UTC ELSE Deleted.ApprovedDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate_UTC ELSE Deleted.DelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate_UTC ELSE Deleted.ApproveDelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creDate_UTC ELSE Deleted.creDate_UTC END,
        CASE WHEN $ACTION = 'INSERT' OR ($ACTION = 'UPDATE' AND Deleted.DInd = 'Y' AND Inserted.DInd = 'N') THEN '01' 
             WHEN $ACTION = 'UPDATE' AND Inserted.DInd = 'Y' THEN '03' 
             ELSE '02' END, 
        GETUTCDATE()
    INTO BSADB.dbo.OFAC_GLSpec_Log (
        ent_num, spec_name, updated_date, remark, DInd, creUserID, IDENTO, STATE, ADDRESS, COUNTRY, 
        GROUPID, IDENT, IDNUM, DOB, Gender, EnterFlag, ApprovedBy, ApprovedDate, 
        DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, CreationDate, 
        updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, CreationDate_UTC, 
        ActionCD, ActionDt
    );

    -- ============================================
    -- 7. Sanctions Control & Ownership (SCO) 清單同步 (2025/12/19 新增獨立流程)
    --    從 Dow Jones 獨立出「控制權與所有權相關」的制裁名單
    -- ============================================
    
    -- 清除舊的 SCO 暫存表
    IF OBJECT_ID('tempdb..#tempDJBlacklistSCO') IS NOT NULL
        DROP TABLE #tempDJBlacklistSCO
    IF OBJECT_ID('tempdb..#tempDJBlacklistDetailsSCO') IS NOT NULL
        DROP TABLE #tempDJBlacklistDetailsSCO

    -- SCO 基本資料暫存表
    CREATE TABLE #tempDJBlacklistSCO (
        EntNum      INT NOT NULL,
        SdnName     NVARCHAR(350) NOT NULL,
        UpdatedDate VARCHAR(8) NOT NULL
    )

    -- SCO 詳細資料暫存表 (多一個 Num 欄位用來存放 ent_num)
    CREATE TABLE #tempDJBlacklistDetailsSCO (
        Num         INT,
        EntNum      INT NOT NULL,
        SdnName     NVARCHAR(350) NOT NULL,
        UpdatedDate VARCHAR(8) NOT NULL,
        Address     NVARCHAR(400),
        City        NVARCHAR(200),
        Country     NVARCHAR(100),
        IdentType   VARCHAR(2),
        IdentNumber NVARCHAR(44),
        DOB         VARCHAR(8)
    )

    -- ============================================
    -- 8. 從 DJ_Entity + DJ_ListCategory 取得 SCO 相關實體
    --    條件: PersonStatus <> 'Inactive' 且 Description3 為特定控制/所有權類別
    --    排除 NameSubType = 'OSN'
    -- ============================================
    INSERT INTO #tempDJBlacklistSCO (EntNum, SdnName, UpdatedDate)
    SELECT C.EntNum, 
           C.SdnName, 
           MAX(C.UpdatedDate) AS UpdatedDate 
    FROM BSADB.dbo.DJ_Entity A 
    JOIN BSADB.dbo.DJ_ListCategory B ON A.EntityId = B.EntityId
    JOIN BSADB.dbo.DJ_List_Data_A C ON A.EntityId = C.EntNum
    LEFT JOIN BSADB.dbo.DJ_AltName D ON C.EntNum = D.EntityId AND C.AltNum = D.AltNameId
    WHERE A.PersonStatus <> 'Inactive' 
      AND B.Description3 IN (
            'OFAC Related - Majority Owned',
            'OFAC Related – Control',
            'OFAC - Regional Sanctions Related - Majority Owned',
            'OFAC - Regional Sanctions Related - Control',
            'EU Related - Majority Owned',
            'EU Related - Control',
            'EU - Regional Sanctions Related - Majority Owned',
            'EU - Regional Sanctions Related – Control'
      ) 
      AND ISNULL(D.NameSubType, '') <> 'OSN'
      AND B.Deleted = 0
    GROUP BY C.EntNum, C.SdnName 

    -- ============================================
    -- 9. 彙總 SanctionListReference (多筆合併成單一字串，以分號分隔)
    --    若超過 400 字元則統一顯示提示訊息
    -- ============================================
    IF OBJECT_ID('tempdb..#DJ_SanctionListReference') IS NOT NULL
        DROP TABLE #DJ_SanctionListReference

    SELECT T.EntityId,
           STUFF((
               SELECT ';' + t2.SanctionListReference
               FROM DJ_SanctionListReference t2
               WHERE t2.EntityId = T.EntityId
               FOR XML PATH(''), TYPE
           ).value('.', 'nvarchar(max)'), 1, 1, '') AS SanctionListReference
    INTO #DJ_SanctionListReference
    FROM DJ_SanctionListReference t
    GROUP BY T.EntityId;
    
    -- 超過長度限制時的處理
    UPDATE #DJ_SanctionListReference
    SET SanctionListReference = 'Visit the Dow Jones for further information'
    WHERE LEN(SanctionListReference) >= 400

    -- ============================================
    -- 10. 取得 BSADBTW..OFAC_SPEC 的最大 ent_num (用於新資料編號)
    -- ============================================
    ;WITH TempAddress AS (
        SELECT A.EntityId, 
               A.SanctionListReference, 
               ROW_NUMBER() OVER (PARTITION BY A.EntityId ORDER BY A.EntityId) AS 'RowId'
        FROM #DJ_SanctionListReference A WITH(NOLOCK) 
        WHERE EXISTS (SELECT 1 FROM #tempDJBlacklistSCO X WHERE A.EntityId = X.EntNum)
    ),
    TempNUM AS (
        -- 從 BSADBTW..OFAC_SPEC 取得已存在的 ent_num (GROUPID=27 且有效資料)
        SELECT A.spec_name, A.updated_date, A.remark, A.TaxID, A.IDENT, A.IDENTO, A.TaxIDCD, A.IDNUM, 
               A.issBy, A.DInd, A.creUserID, A.STATE, A.ADDRESS, A.COUNTRY,
               A.GROUPID, A.SOURCE, A.EnterFlag, A.ApprovedBy, A.ApprovedDate, 
               A.DelUserID, A.DelDate, A.ApproveDelUserID, A.ApproveDelDate, A.creDate,
               A.updated_date_UTC, A.ApprovedDate_UTC, A.DelDate_UTC, A.ApproveDelDate_UTC, A.creDate_UTC, 
               A.ent_num, A.DOB
        FROM BSADBTW..OFAC_SPEC A 
        WHERE A.GROUPID = 27 
          AND A.DInd = 'N'
    )
    INSERT INTO #tempDJBlacklistDetailsSCO (Num, EntNum, SdnName, UpdatedDate, Address)
    SELECT E.ent_num, 
           A.EntNum, 
           A.SdnName, 
           A.UpdatedDate, 
           B.SanctionListReference
    FROM #tempDJBlacklistSCO A 
        LEFT JOIN TempAddress B ON A.EntNum = B.EntityId AND B.RowId = 1 
        LEFT JOIN TempNUM E ON A.EntNum = E.remark AND A.SdnName = E.spec_name

    -- 為新資料指派新的 ent_num (從目前最大值開始累加)
    DECLARE @MAXNo INT
    SELECT @MAXNo = MAX(ent_num) FROM BSADBTW..OFAC_SPEC

    UPDATE #tempDJBlacklistDetailsSCO
    SET @MAXNo = @MAXNo + 1,
        Num = @MAXNo
    WHERE Num IS NULL

    -- ============================================
    -- 11. MERGE 至 BSADBTW..OFAC_SPEC (SCO 清單，GROUPID=27)
    -- ============================================
    ;WITH TargetTable AS (
        SELECT A.spec_name, A.updated_date, A.remark, A.TaxID, A.IDENT, A.IDENTO, A.TaxIDCD, A.IDNUM, 
               A.issBy, A.DInd, A.creUserID, A.STATE, A.ADDRESS, A.COUNTRY,
               A.GROUPID, A.SOURCE, A.EnterFlag, A.ApprovedBy, A.ApprovedDate, 
               A.DelUserID, A.DelDate, A.ApproveDelUserID, A.ApproveDelDate, A.creDate,
               A.updated_date_UTC, A.ApprovedDate_UTC, A.DelDate_UTC, A.ApproveDelDate_UTC, A.creDate_UTC, 
               A.ent_num, A.DOB
        FROM BSADBTW..OFAC_SPEC A 
        WHERE A.GROUPID = 27
    )
    MERGE TargetTable T
    USING (
        SELECT NUM, EntNum, SdnName, UpdatedDate, Address, City, Country, 
               IdentType, IdentNumber, DOB 
        FROM #tempDJBlacklistDetailsSCO
    ) S
    ON T.spec_name = S.SdnName 
   AND T.remark = CAST(S.EntNum AS VARCHAR(100))
    
    -- 新增 SCO 資料
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (spec_name, updated_date, remark, TaxID, IDENT, IDENTO, TaxIDCD, IDNUM, IssBy, DInd,
                creUserID, STATE, ADDRESS, COUNTRY, GROUPID, SOURCE, EnterFlag, 
                ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, 
                creDate, updated_date_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, creDate_UTC,
                ent_num, DOB)
        VALUES (S.SdnName, S.UpdatedDate, S.EntNum, '', S.IdentType, S.IdentNumber, '', '', '', 'N', 
                'System Admin', ISNULL(S.City,''), S.Address, S.Country, '27', 'Sanctions Control Ownership', 'D', 
                'System Admin', GETDATE(), NULL, NULL, NULL, NULL, GETDATE(), GETUTCDATE(), GETUTCDATE(), 
                NULL, NULL, GETUTCDATE(), S.num, S.DOB)
    
    -- 軟刪除 (目標有、來源沒有)
    WHEN NOT MATCHED BY SOURCE AND T.DInd = 'N' THEN 
        UPDATE SET T.DInd = 'Y', 
                   T.DelUserID = 'System Admin', 
                   T.DelDate = GETDATE(), 
                   T.ApproveDelUserID = 'System Admin', 
                   T.ApproveDelDate = GETDATE(),
                   T.DelDate_UTC = GETUTCDATE()
    
    -- 更新 (日期不同或恢復已刪除資料)
    WHEN MATCHED AND (T.DInd = 'Y' OR S.UpdatedDate <> T.updated_date) THEN 
        UPDATE SET T.DInd = 'N', 
                   T.updated_date = S.UpdatedDate, 
                   T.DelUserID = NULL, 
                   T.DelDate = NULL, 
                   T.ApproveDelUserID = NULL, 
                   T.ApproveDelDate = NULL,
                   T.DelDate_UTC = NULL, 
                   T.EnterFlag = 'D', 
                   T.updated_date_UTC = GETUTCDATE(),
                   T.ADDRESS = S.ADDRESS, 
                   T.STATE = ISNULL(S.City,''), 
                   T.COUNTRY = S.Country, 
                   T.IDENT = S.IdentType, 
                   T.IDNUM = S.IdentNumber, 
                   T.DOB = S.DOB
    
    -- 輸出 Log 至 BSADBTW.dbo.OFAC_SPEC_LOG
    OUTPUT 
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ent_num ELSE Deleted.ent_num END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.spec_name ELSE Deleted.spec_name END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.updated_date ELSE Deleted.updated_date END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.remark ELSE Deleted.remark END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.taxid ELSE Deleted.taxid END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENT ELSE Deleted.IDENT END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDENTO ELSE Deleted.IDENTO END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.TaxIDCD ELSE Deleted.TaxIDCD END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.IDNUM ELSE Deleted.IDNUM END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.issby ELSE Deleted.issby END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DInd ELSE Deleted.DInd END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.creUserID ELSE Deleted.creUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN 'System Admin' ELSE 'System Admin' END,
        CASE WHEN $ACTION IN ('INSERT') THEN GETUTCDATE() ELSE GETUTCDATE() END,		
        CASE WHEN $ACTION = 'INSERT' OR ($ACTION = 'UPDATE' AND Deleted.DInd = 'Y' AND Inserted.DInd = 'N') THEN '01' 
             WHEN $ACTION = 'UPDATE' AND Inserted.DInd = 'Y' THEN '03' 
             ELSE '02' END, 
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ADDRESS ELSE Deleted.ADDRESS END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.STATE ELSE Deleted.STATE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.COUNTRY ELSE Deleted.COUNTRY END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.GROUPID ELSE Deleted.GROUPID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.SOURCE ELSE Deleted.SOURCE END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.EnterFlag ELSE Deleted.EnterFlag END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedBy ELSE Deleted.ApprovedBy END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate ELSE Deleted.ApprovedDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelUserID ELSE Deleted.DelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate ELSE Deleted.DelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelUserID ELSE Deleted.ApproveDelUserID END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate ELSE Deleted.ApproveDelDate END,
        CASE WHEN $ACTION IN ('INSERT') THEN GETUTCDATE() ELSE GETUTCDATE() END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApprovedDate_UTC ELSE Deleted.ApprovedDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DelDate_UTC ELSE Deleted.DelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.ApproveDelDate_UTC ELSE Deleted.ApproveDelDate_UTC END,
        CASE WHEN $ACTION IN ('INSERT') THEN Inserted.DOB ELSE Deleted.DOB END
    INTO BSADBTW.dbo.OFAC_SPEC_LOG (
        ent_num, spec_name, updated_date, remark, TaxID, IDENT, IDENTO,
        TaxIDCD, IDNUM, IssBy, DInd, creUserID, UserID, ActionDT, ActionCD, 
        Address, State, Country, GROUPID, SOURCE, EnterFlag,
        ApprovedBy, ApprovedDate, DelUserID, DelDate, ApproveDelUserID, ApproveDelDate, 
        ActionDT_UTC, ApprovedDate_UTC, DelDate_UTC, ApproveDelDate_UTC, DOB
    );

END
GO
