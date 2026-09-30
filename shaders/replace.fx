// Minimaler Textur-Ersatz-Shader (wie im MTA-Wiki: Texture Replacement).
// Wird fuer Kategorien vom Typ "texture" (z. B. Backlights) verwendet.
texture gTexture;

technique TexReplace
{
    pass P0
    {
        Texture[0] = gTexture;
    }
}
