/*
Copyright © 2021 Sungbae Jeong <almagest0328@gmail.com>
*/
package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// initCmd represents the init command
var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Initialize a vesti project",
	Long:  "",
	//Args:  cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("This is experimental, so it doesn't anything")
	},
}

func init() {
	rootCmd.AddCommand(initCmd)
}
