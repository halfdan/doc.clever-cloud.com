--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
import           Control.Applicative ((<$>))
import           Control.Monad       (forM_, mapM, (>=>))
import           Data.List           (intersperse, sortBy)
import           Data.Maybe          (fromMaybe)
import           Data.Monoid         (mappend,mempty)
import           Data.Ord            (comparing)
import           Hakyll
import           Text.Pandoc.Options
import           System.FilePath.Posix  (dropExtension,dropFileName,(</>),splitDirectories,joinPath,takeBaseName,takeFileName)
import qualified Data.Map as M
import qualified Data.Set as S
--------------------------------------------------------------------------------

customPandocCompiler :: Compiler (Item String)
customPandocCompiler =
    let customExtensions = [Ext_raw_html,Ext_markdown_in_html_blocks]
        defaultExtensions = readerExtensions defaultHakyllReaderOptions
        defaultWExtensions = writerExtensions defaultHakyllWriterOptions
        newExtensions = foldr S.insert defaultExtensions customExtensions
        newWExtensions = foldr S.insert defaultWExtensions customExtensions
        readerOptions = defaultHakyllReaderOptions {
                          readerExtensions = newExtensions
                        }
        writerOptions = defaultHakyllWriterOptions {
                          writerExtensions = newWExtensions
                        }
    in pandocCompilerWith readerOptions writerOptions

main :: IO ()
main = hakyll $ do

    -- Copy files and images
    match ("assets/images/**" .||. "assets/js/*" .||. "assets/font/*" .||. "assets/magnific-popup/*") $ do
        route   idRoute
        compile copyFileCompiler

    -- Compress css
    match "assets/css/*.css" $ do
        route   idRoute
        compile compressCssCompiler

    match "assets/css/**.less" $ do
        compile $ getResourceBody

    d <- makePatternDependency $ "assets/css/**.less"
    rulesExtraDependencies [d] $ create ["assets/css/all.css"] $ do
       route idRoute
       compile $
        loadBody "assets/css/all.less"
        >>= makeItem
        >>= withItemBody (unixFilter "lessc" ["-"])

    match "index.html" $ do
        route $ idRoute
        compile $ getResourceBody
            >>= loadAndApplyTemplate "templates/default.html" mainCtx
            >>= cleanUrls

    match "write-a-tutorial-and-get-rewarded.html" $ do
        route $ idRoute
        compile $ getResourceBody
            >>= loadAndApplyTemplate "templates/default.html" mainCtx
            >>= cleanUrls

    match "search.html" $ do
        route $ idRoute
        compile $ getResourceBody
            >>= loadAndApplyTemplate "templates/default.html" mainCtx
            >>= cleanUrls

    match "templates/*" $ compile templateCompiler

    forM_ ["commons", "runtimes"] $ (\dir ->
        match (fromGlob $ dir ++ "/*.md") $ do
            route niceRoute
            compile (getResourceBody >>= makeCatPage dir))

    forM_ ["commons", "runtimes"] $ (\dir ->
        match (fromGlob $ dir ++ "/*/*.md") $ do
            route niceRoute
            compile $
                customPandocCompiler
                    >>= loadAndApplyTemplate "templates/default.html" mainCtx >>= cleanUrls)

--------------------------------------------------------------------------------
mainCtx :: Context String
mainCtx =
    field "commons" makeCommonsMenu `mappend`
    field "runtimes" makeRuntimesMenu `mappend`
    defaultContext

cleanUrls :: Item String -> Compiler (Item String)
cleanUrls = relativizeUrls . fmap removeIndexInUrls

removeIndexInUrls :: String -> String
removeIndexInUrls = withUrls cleanUrl
  where
    cleanUrl u =
        if (not $ isExternal u) then removeIndex u
        else u
    removeIndex u =
        if(takeFileName u == "index.html") then dropFileName u
        else u

--------------------------------------------------------------------------------
--
-- replace a foo/bar.md by foo/bar/index.html
-- this way the url looks like: foo/bar in most browsers
niceRoute :: Routes
niceRoute = customRoute createIndexRoute
  where
    createIndexRoute ident = withoutCategory </> "index.html"
      where p = toFilePath ident
            withoutCategory = joinPath . drop 1 . splitDirectories $ dropExtension p

makeCommonsMenu :: Item String -> Compiler String
makeCommonsMenu item = do
    ordered_categories_md <- fmap sortByPosition $  getAllMetadata "commons/*.md"
    blocks <- mapM (makeCategoryMenuItem "commons" item) ordered_categories_md
    mapM_ (debugCompiler . show) blocks
    tpl <- loadBody "templates/menu-category.html"
    applyTemplateList tpl ctx blocks
  where
    ctx = defaultContext

makeRuntimesMenu :: Item String -> Compiler String
makeRuntimesMenu item = do
    ordered_categories_md <- fmap sortByPosition $  getAllMetadata "runtimes/*.md"
    blocks <- mapM (makeCategoryMenuItem "commons" item) ordered_categories_md
    blocks <- mapM (makeCategoryMenuItem "runtimes" item) ordered_categories_md
    mapM_ (debugCompiler . show) blocks
    tpl <- loadBody "templates/menu-category.html"
    applyTemplateList tpl ctx blocks
  where
    ctx = defaultContext

makeCatPage :: String -> Item String -> Compiler (Item String)
makeCatPage dir cat = do
    md <- getMetadata $ itemIdentifier cat
    ordered_pages_md <- fmap sortByPosition $ getAllMetadata (fromGlob $ dir ++ "/" ++ category_id ++ "/*.md")
    tpl <- loadBody "templates/cat-index-item.html"
    applyTemplateListWithContexts tpl (makeItemContextPairList ordered_pages_md)
        >>= makeItem
        >>= loadAndApplyTemplate "templates/category-page.html" mainCtx
        >>= loadAndApplyTemplate "templates/default.html" mainCtx
        >>= cleanUrls
  where
    category_name md = fromMaybe "" $ M.lookup "name" md
    category_id = takeBaseName . toFilePath . itemIdentifier $ cat

makeCategoryMenuItem :: String -> Item String -> (Identifier,Metadata) -> Compiler (Item String)
makeCategoryMenuItem dir current (id, md) = mkItem $ do
    ordered_pages_md <- fmap sortByPosition $ getAllMetadata (fromGlob $ dir ++ "/" ++ category_id ++ "/*.md")
    tpl <- loadBody "templates/menu-item.html"
    applyTemplateListWithContexts tpl (makeItemContextPairListWith ordered_pages_md mkCtx)
  where
    mkItem = fmap (Item id)
    category_name = fromMaybe "" $ M.lookup "name" md
    category_id = takeBaseName . toFilePath $ id
    mkCtx id = constField "active" $
        if id == itemIdentifier current then " class=\"cc-sidebar__item__active\""
        else ""

makeDefaultContext :: (Identifier, Metadata) -> Context String
makeDefaultContext (i, m) =
        makeUrlField i `mappend`
        makeMetadataContext m
    where
        makeMetadataContext m =
            (Context $ \k _ -> do
                return $ return $ StringField $ fromMaybe "" $ M.lookup k m)

        makeUrlField id =
            field "url" $ \_ -> do
                fp <- getRoute id
                return $ fromMaybe "" $ fmap toUrl fp

makeItemContextPairList :: [(Identifier, Metadata)] -> [(Context String, Item String)]
makeItemContextPairList ims =
    makeItemContextPairListWith ims (const mempty)

makeItemContextPairListWith :: [(Identifier, Metadata)]
                            -> (Identifier -> Context String)
                            -> [(Context String, Item String)]
makeItemContextPairListWith ims a = map f ims
    where
    f p = ((a $ fst p) `mappend` makeDefaultContext p, Item (fst p) "")

applyTemplateListWithContexts :: Template
                              -> [(Context a, Item a)]
                              -> Compiler String
applyTemplateListWithContexts =
    applyJoinTemplateListWithContexts ""

applyJoinTemplateListWithContexts :: String
                                  -> Template
                                  -> [(Context a, Item a)]
                                  -> Compiler String
applyJoinTemplateListWithContexts delimiter tpl pairs = do
    items <- mapM (\p -> applyTemplate tpl (fst p) (snd p)) pairs
    return $ concat $ intersperse delimiter $ map itemBody items

sortByPosition :: [(Identifier, Metadata)] -> [(Identifier, Metadata)]
sortByPosition = sortBy (comparing (getPosition . snd))
  where
    getPosition md = fmap read $ M.lookup "position" md :: Maybe Int
