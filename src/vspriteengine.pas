unit vspriteengine;
{$include valkyrie.inc}
interface
uses SysUtils, vgenerics, vvector, vrltools, vcolor, vgltypes, vglprogram, vglquadarrays, vtextures;

type TSpriteEngine = class;

type

{ TSpriteDataSet }

TSpriteDataSet = class
  constructor Create( aEngine : TSpriteEngine; aNormal, aCosplay, aEmissive : TTexture; aOrder : Integer );
  procedure Push( aSpriteID : DWord; aCoord : TCoord2D; aColor, aCosColor : TColor; aZ : Integer = 0 );
  procedure PushXY( aSpriteID, aSize : DWord; aPos : TVec2i; aQColor : PGLRawQColor; aCosColor : TColor; TShiftX : Single = 0; TShiftY : Single = 0; aZ : Integer = 0 );
  procedure PushXY( aSpriteID, aSize : DWord; aPos : TVec2i; aColor, aCosColor : TColor; aZ : Integer = 0 );
  procedure Push( aQCoord : PGLRawQCoord; aQTex : PGLRawQTexCoord; aQColor : PGLRawQColor; aCosColor : TColor; aZ : Integer = 0 );
  procedure PushPart( aSpriteID : DWord; aPa, aPb : TVec2i; aQColor : PGLRawQColor; aCosColor : TColor; aZ : Integer; aTa, aTb : TVec2f );
  destructor Destroy; override;
private
  FData        : TGLTexturedColored2Quads;
  FEngine      : TSpriteEngine;
  FTexUnit     : TVec2f;
  FRowSize     : Word;
  FTNormalID   : DWord;
  FTCosplayID  : DWord;
  FTEmissiveID : DWord;
  FOrder       : Integer;
public
  property TexUnit     : TVec2f  read FTexUnit;
  property RowSize     : Word    read FRowSize;
  property TNormalID   : DWord   read FTNormalID;
  property TCosplayID  : DWord   read FTCosplayID;
  property TEmissiveID : DWord   read FTEmissiveID;
  property Order       : Integer read FOrder;
end;

type TSpriteDataSetArray = specialize TGArray< TSpriteDataSet >;

{ TSpriteEngine }

TSpriteEngine = class
  constructor Create( aTileSize : TVec2i; aScale : Byte = 1 );
  procedure SetScale( aScale : Byte );
  procedure Draw;
  procedure Update( aProjection : TMatrix44 );
  procedure DrawSet( const Data : TSpriteDataSet );
  function Add( aNormal, aCosplay, aEmissive : TTexture; aOrder : Integer ) : Integer;
  destructor Destroy; override;
private
  procedure SetTexture( aTextureID : DWord );
private

  FVAO            : Cardinal;
  FProgram        : TGLProgram;
  FProjection     : TMatrix44;
  FCurrentTexture : DWord;
  FGrid           : TVec2i;
  FTileSize       : TVec2i;
  FPosition       : TVec2i;
  FLayersDirty    : Boolean;
  FLayers         : TSpriteDataSetArray;
  FLayersSorted   : TSpriteDataSetArray;
  FTZeroID        : DWord;
public
  property Grid     : TVec2i read FGrid;
  property TileSize : TVec2i read FTileSize;
  property Position : TVec2i read FPosition write FPosition;
  property Layers   : TSpriteDataSetArray read FLayers;
end;


implementation

uses vgl3library, vdebug;

const
VSpriteVertexShader : Ansistring =
'#version 330 core'+#10+
'layout (location = 0) in vec3 position;'+#10+
'layout (location = 1) in vec2 texcoord;'+#10+
'layout (location = 2) in vec4 color;'+#10+
'layout (location = 3) in vec4 color2;'+#10+
'uniform mat4 utransform;'+#10+
'uniform vec3 uposition;'+#10+
#10+
'out vec4 ocolor;'+#10+
'out vec4 ocolor2;'+#10+
'out vec2 otexcoord;'+#10+
#10+
'void main() {'+#10+
'ocolor    = color;'+#10+
'ocolor2   = color2;'+#10+
'otexcoord = texcoord;'+#10+
'gl_Position = utransform * vec4(uposition + position, 1.0);'+#10+
'}'+#10;
VSpriteFragmentShader : Ansistring =
'#version 330 core'+#10+
'in vec4 ocolor;'+#10+
'in vec4 ocolor2;'+#10+
'in vec2 otexcoord;'+#10+
'uniform sampler2D unormal;'+#10+
'uniform sampler2D ucosplay;'+#10+
'uniform sampler2D uemissive;'+#10+
'layout (location = 0) out vec4 frag_color;'+#10+
'layout (location = 1) out vec4 emissive_color;'+#10+
#10+
'void main() {'+#10+
'frag_color     = texture(unormal, otexcoord) + vec4( texture(ucosplay, otexcoord).xyz, 0 ) * ocolor2;'+#10+
'float emissive = texture(uemissive, otexcoord).x;'+#10+
'vec4 color     = vec4( max( ocolor.xyz, vec3(emissive) ), ocolor.w );'+#10+
'frag_color     = frag_color * color;'+#10+
'emissive_color = vec4( emissive * frag_color.xyz, frag_color.w );'+#10+
'}'+#10;

{ TSpriteDataSet }

constructor TSpriteDataSet.Create( aEngine : TSpriteEngine; aNormal, aCosplay, aEmissive : TTexture; aOrder : Integer );
var iTilesY : Integer;
begin
  Assert( aNormal <> nil, 'Nil texture passed!');
  FEngine      := aEngine;
  FData        := TGLTexturedColored2Quads.Create;
  FTNormalID   := aNormal.GLTexture;
  FTCosplayID  := 0;
  FTEmissiveID := 0;
  if aCosplay <> nil  then FTCosplayID  := aCosplay.GLTexture;
  if aEmissive <> nil then FTEmissiveID := aEmissive.GLTexture;
  FRowSize     := aNormal.Size.X div FEngine.TileSize.X;
  iTilesY      := aNormal.Size.Y div FEngine.TileSize.Y;
  FTexUnit.Init( 1.0 / FRowSize, 1.0 / iTilesY );
  FOrder       := aOrder;
end;

destructor TSpriteDataSet.Destroy;
begin
  FreeAndNil( FData );
end;

{ TSpriteDataVTC }

procedure TSpriteDataSet.Push( aSpriteID : DWord; aCoord : TCoord2D; aColor, aCosColor : TColor; aZ : Integer = 0);
var iv2a, iv2b    : TVec2i;
    ita, itb, its : TVec2f;
begin
  iv2a := Vec2i( aCoord.X-1, aCoord.Y-1 ) * FEngine.FGrid;
  iv2b := Vec2i( aCoord.X, aCoord.Y )     * FEngine.FGrid;

  its := TVec2f.CreateModDiv( aSpriteID-1, FRowSize );
  ita := its * FTexUnit;
  itb := its.Shifted(1) * FTexUnit;

  FData.PushQuad(
    TVec3i.CreateFrom( iv2a, aZ ),
    TVec3i.CreateFrom( iv2b, aZ ),
    aColor.toVec43f,
    aCosColor.toVec43f,
    ita, itb
  );

end;

procedure TSpriteDataSet.PushXY( aSpriteID, aSize : DWord; aPos : TVec2i; aQColor : PGLRawQColor; aCosColor : TColor; TShiftX : Single = 0; TShiftY : Single = 0; aZ : Integer = 0 );
var iv2b          : TVec2i;
    ita, itb, its : TVec2f;
begin
  iv2b := aPos + FEngine.FGrid.Scaled( aSize );

  its := TVec2f.CreateModDiv( aSpriteID-1, FRowSize );
  its += TVec2f.Create( TShiftX, TShiftY );

  ita := its * FTexUnit;
  itb := its.Shifted( aSize ) * FTexUnit;

  FData.PushQuad(
    TVec3i.CreateFrom( aPos, aZ ),
    TVec3i.CreateFrom( iv2b, aZ ),
    TGLQVec4f.Create(
      NewColor( aQColor^.Data[0] ).toVec43f,
      NewColor( aQColor^.Data[1] ).toVec43f,
      NewColor( aQColor^.Data[2] ).toVec43f,
      NewColor( aQColor^.Data[3] ).toVec43f
    ),
    aCosColor.toVec43f,
    ita, itb
  );
end;

procedure TSpriteDataSet.PushXY( aSpriteID, aSize : DWord; aPos : TVec2i; aColor, aCosColor : TColor; aZ : Integer = 0 );
var iv2b          : TVec2i;
    ita, itb, its : TVec2f;
begin
  iv2b := aPos + FEngine.FGrid.Scaled( aSize );
  its := TVec2f.CreateModDiv( aSpriteID-1, FRowSize );

  ita := its * FTexUnit;
  itb := its.Shifted( aSize ) * FTexUnit;

  FData.PushQuad(
    TVec3i.CreateFrom( aPos, aZ ),
    TVec3i.CreateFrom( iv2b, aZ ),
    aColor.toVec43f,
    aCosColor.toVec43f,
    ita, itb
  );
end;

procedure TSpriteDataSet.Push( aQCoord : PGLRawQCoord; aQTex : PGLRawQTexCoord; aQColor : PGLRawQColor; aCosColor : TColor; aZ : Integer = 0);
begin
  FData.PushQuad(
    TGLQVec3i.Create(
      TVec3i.CreateFrom( aQCoord^.Data[0], aZ ),
      TVec3i.CreateFrom( aQCoord^.Data[1], aZ ),
      TVec3i.CreateFrom( aQCoord^.Data[2], aZ ),
      TVec3i.CreateFrom( aQCoord^.Data[3], aZ )
    ),
    TGLQVec4f.Create(
      NewColor( aQColor^.Data[0] ).toVec43f,
      NewColor( aQColor^.Data[1] ).toVec43f,
      NewColor( aQColor^.Data[2] ).toVec43f,
      NewColor( aQColor^.Data[3] ).toVec43f
    ),
    aCosColor.toVec43f,
    aQTex^.Data[0], aQTex^.Data[2]
  );
end;

procedure TSpriteDataSet.PushPart( aSpriteID : DWord; aPa, aPb : TVec2i; aQColor : PGLRawQColor; aCosColor : TColor; aZ : Integer; aTa, aTb : TVec2f );
var its : TVec2f;
begin
  its := TVec2f.CreateModDiv( aSpriteID-1, FRowSize );
  ata := ( its + aTa ) * FTexUnit;
  atb := ( its + aTb ) * FTexUnit;

  FData.PushQuad(
    TVec3i.CreateFrom( aPa, aZ ),
    TVec3i.CreateFrom( aPb, aZ ),
    TGLQVec4f.Create(
      NewColor( aQColor^.Data[0] ).toVec43f,
      NewColor( aQColor^.Data[1] ).toVec43f,
      NewColor( aQColor^.Data[2] ).toVec43f,
      NewColor( aQColor^.Data[3] ).toVec43f
    ),
    aCosColor.toVec43f,
    ata, atb
  );
end;

{ TSpriteEngine }

procedure TSpriteEngine.Update ( aProjection : TMatrix44 );
var i : Integer;
begin
  for i := 0 to 15 do
    if FProjection[i] <> aProjection[i] then
    begin
      FProjection := aProjection;
      FProgram.Bind;
      glUniformMatrix4fv( FProgram.GetUniformLocation( 'utransform' ), 1, GL_FALSE, @FProjection[0] );
      glUniform1i( FProgram.GetUniformLocation('unormal'), 0 );
      glUniform1i( FProgram.GetUniformLocation('ucosplay'), 1 );
      glUniform1i( FProgram.GetUniformLocation('uemissive'), 2 );
      FProgram.UnBind;
      Exit;
    end;
end;

procedure TSpriteEngine.DrawSet(const Data: TSpriteDataSet );
begin
  glActiveTexture( GL_TEXTURE0 );

  glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );

  if not Data.FData.Empty then
  begin
    glActiveTexture( GL_TEXTURE0 );
    SetTexture( Data.TNormalID );
    glActiveTexture( GL_TEXTURE1 );
    SetTexture( Data.TCosplayID );
    glActiveTexture( GL_TEXTURE2 );
    SetTexture( Data.TEmissiveID );
    FProgram.Bind;
    Data.FData.Update;
    Data.FData.Draw;
    Data.FData.Clear;
    FProgram.UnBind;
  end;

  glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );
end;

procedure TSpriteEngine.SetTexture( aTextureID : DWord );
begin
  if aTextureID <> 0
    then glBindTexture( GL_TEXTURE_2D, aTextureID )
    else glBindTexture( GL_TEXTURE_2D, FTZeroID );
end;

destructor TSpriteEngine.Destroy;
var iSet : TSpriteDataSet;
begin
  for iSet in FLayers do
    iSet.Free;
  glDeleteVertexArrays(1, @FVAO);
  FreeAndNil( FProgram );
  FreeAndNil( FLayers );
  FreeAndNil( FLayersSorted );
end;

constructor TSpriteEngine.Create( aTileSize : TVec2i; aScale : Byte = 1 );
var iZeroPixel : array[0..3] of GLubyte = (0, 0, 0, 0);
begin
  FTileSize := aTileSize;
  SetScale( aScale );
  FPosition.Init(0,0);
  FCurrentTexture    := 0;
  FLayersDirty       := True;

  FProgram := TGLProgram.Create( VSpriteVertexShader, VSpriteFragmentShader );
  glGenVertexArrays(1, @FVAO);

  FLayers       := TSpriteDataSetArray.Create;
  FLayersSorted := TSpriteDataSetArray.Create;

  // Create dummy texture
  glGenTextures(1, @FTZeroID );
  glBindTexture( GL_TEXTURE_2D, FTZeroID );
    glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, @iZeroPixel );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
    glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
  glBindTexture( GL_TEXTURE_2D, 0 );

end;

procedure TSpriteEngine.SetScale( aScale : Byte );
begin
  FGrid.Init( FTileSize.X * aScale, FTileSize.Y * aScale );
end;

function TSpriteEngine.Add( aNormal, aCosplay, aEmissive : TTexture; aOrder : Integer ) : Integer;
var i : DWord;
begin
  Assert( aNormal <> nil, 'Normal texture needs to be present in spritesheet!');
  if FLayers.Size > 0 then
  for i := 0 to FLayers.Size - 1 do
    if FLayers[i].TNormalID = aNormal.GLTexture then
      Exit(i);
  FLayersDirty := True;
  FLayers.Push( TSpriteDataSet.Create( Self, aNormal, aCosplay, aEmissive, aOrder ) );
  Exit( Flayers.Size - 1 );
end;

function SpriteEngineLayerSort( const aLayerA, aLayerB : TSpriteDataSet ) : Integer;
begin
  Exit( aLayerA.Order - aLayerB.Order );
end;

procedure TSpriteEngine.Draw;
var iSet : TSpriteDataSet;
begin
  if FLayersDirty then
  begin
    FLayersSorted.Clear;
    for iSet in FLayers do
      FLayersSorted.Push( iSet );
    FLayersSorted.Sort( @SpriteEngineLayerSort );
    FLayersDirty := False;
  end;

  FCurrentTexture := 0;
  FProgram.Bind;
  glUniform3f( FProgram.GetUniformLocation('uposition'), -FPosition.X, -FPosition.Y, 0 );
  for iSet in FLayersSorted do
    DrawSet( iSet );
  glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );
end;

initialization

  Assert( SizeOf( Integer ) = SizeOf( GLInt ) );
  Assert( SizeOf( Single )  = SizeOf( GLFloat ) );
  Assert( SizeOf( TGLRawQCoord )    = 8 * SizeOf( GLInt ) );
  Assert( SizeOf( TGLRawQTexCoord ) = 8 * SizeOf( GLFloat ) );
  Assert( SizeOf( TGLRawQColor )    = 12 * SizeOf( GLByte ) );

end.

